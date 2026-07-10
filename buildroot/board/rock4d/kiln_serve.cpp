// SPDX-License-Identifier: Apache-2.0
// kiln-serve -- an OpenAI-compatible HTTP API for the NPU. It wraps the SAME
// RKLLM/RKNN call sequences as kiln-chat / kiln-vision (via kiln_llm.h /
// kiln_vision.h), so nothing about inference is re-implemented -- only an HTTP +
// SSE layer on top. Config comes from the unified /etc/kiln/config.ini.
//
//   GET  /health               liveness
//   GET  /v1/models            list the .rkllm model(s)
//   POST /v1/chat/completions  OpenAI chat; `stream:true` -> SSE token stream
//   POST /v1/vision/classify   image -> top-N classes (custom shape)
//
// The LLM and the vision model are each loaded once at startup and are BOTH
// optional: a vision-only box (e.g. RK3568, no .rkllm) serves vision and answers
// 503 on /v1/chat/completions; an LLM-only box serves chat. The NPU is
// single-tenant, so requests are serialized in kiln_llm / kiln_vision.
// Build: needs httplib.h (cpp-httplib) + json.hpp (nlohmann/json), both
// header-only, fetched by buildroot/fetch-runtimes.sh. No runtime deps beyond
// librkllmrt + libgomp.
#include "httplib.h"
#include "json.hpp"
#include "kiln_config.h"
#include "kiln_llm.h"
#define STB_IMAGE_IMPLEMENTATION
#include "kiln_vision.h"   // optional /v1/vision/classify (pulls in stb decoder)
#include "kiln_detect.h"   // optional /v1/vision/detect (EXPERIMENTAL YOLOv8/11)

#include <atomic>
#include <memory>
#include <cstdio>
#include <ctime>
#include <string>
#include <vector>
#include <dirent.h>

using nlohmann::json;

static std::string now_id(const char *prefix) {
    static std::atomic<unsigned long> seq{0};
    char buf[64];
    snprintf(buf, sizeof(buf), "%s-%ld%03lu", prefix, (long)time(nullptr),
             (seq++ % 1000));
    return buf;
}

// Flatten OpenAI messages -> one ChatML string (stateless; the client resends
// the whole history each request, which is the OpenAI contract).
static std::string build_chatml(const json &messages, const std::string &default_system) {
    std::string s;
    bool has_system = false;
    for (const auto &m : messages) {
        std::string role = m.value("role", "user");
        std::string content;
        if (m.contains("content") && m["content"].is_string())
            content = m["content"].get<std::string>();
        else if (m.contains("content") && m["content"].is_array()) {
            // multimodal array: concatenate the text parts
            for (const auto &part : m["content"])
                if (part.value("type", "") == "text") content += part.value("text", "");
        }
        if (role == "system") has_system = true;
        s += "<|im_start|>" + role + "\n" + content + "<|im_end|>\n";
    }
    if (!has_system && !default_system.empty())
        s = "<|im_start|>system\n" + default_system + "<|im_end|>\n" + s;
    s += "<|im_start|>assistant\n";
    return s;
}

// List *.rkllm next to the loaded model so /v1/models is honest about the box.
static std::vector<std::string> list_models(const std::string &model_path) {
    std::vector<std::string> out;
    std::string dir = model_path.substr(0, model_path.find_last_of('/'));
    if (dir.empty()) dir = ".";
    DIR *d = opendir(dir.c_str());
    if (!d) return out;
    for (dirent *e; (e = readdir(d));) {
        std::string n = e->d_name;
        if (n.size() > 6 && n.substr(n.size() - 6) == ".rkllm")
            out.push_back(dir + "/" + n);
    }
    closedir(d);
    return out;
}

int main(int argc, char **argv) {
    KilnConfig cfg;
    kiln::load(cfg);  // /etc/kiln/config.ini (or $KILN_CONFIG); defaults if absent

    // allow `kiln-serve --host H --port P` to override the config for a quick run
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i];
        if (k == "--host") cfg.server_host = argv[i + 1];
        else if (k == "--port") cfg.server_port = atoi(argv[i + 1]);
        else if (k == "--model") cfg.server_llm_model = argv[i + 1];
    }

    // AUTO-DISCOVER the LLM (Kiln hard-codes none): the configured [server].llm_model
    // / [llm].model if it exists, else the first *.rkllm in /opt/models. Empty -> no
    // LLM (vision-only), which is a valid mode (e.g. RK3568).
    const std::string model_path = kiln::resolve_model(cfg.server_llm(), ".rkllm");
    const std::string model_name = model_path.empty() ? "" : model_path.substr(model_path.find_last_of('/') + 1);

    // Optional LLM: RK3568 (and any vision-only box) has no .rkllm, so don't hard
    // fail -- start vision-only and let /v1/chat/completions answer 503.
    std::unique_ptr<KilnLLM> llm;
    {
        FILE *mf = fopen(model_path.c_str(), "rb");
        if (mf) {
            fclose(mf);
            printf("kiln-serve: loading %s onto the NPU ...\n", model_path.c_str());
            KilnConfig lc = cfg;
            lc.llm_model = model_path;
            llm.reset(new KilnLLM());
            if (llm->init(lc) != 0) {
                fprintf(stderr, "kiln-serve: LLM disabled (rkllm_init failed for %s)\n", model_path.c_str());
                llm.reset();
            } else {
                llm->set_chat_template("", "", "");  // we pass a full ChatML string
                printf("kiln-serve: LLM ready (%s)\n", model_name.c_str());
            }
        } else {
            printf("kiln-serve: no LLM model at %s -- vision-only mode\n", model_path.c_str());
        }
    }

    // Optional vision: only load it if the .rknn exists, so a box that only wants
    // the LLM doesn't pay for it (and it never crashes when absent).
    std::unique_ptr<KilnVision> vision;
    std::unique_ptr<KilnDetect> detector;   // EXPERIMENTAL: [vision] task = detect
    {
        KilnConfig vc = cfg; vc.vision_model = kiln::resolve_model(cfg.server_vision(), ".rknn");
        FILE *vf = fopen(vc.vision_model.c_str(), "rb");
        if (vf) {
            fclose(vf);
            if (vc.vision_task == "detect") {
                // the .rknn is a YOLO detector, not a classifier -> /v1/vision/detect
                detector.reset(new KilnDetect());
                if (detector->init(vc) != 0) {
                    fprintf(stderr, "kiln-serve: detection disabled (%s)\n", detector->error());
                    detector.reset();
                } else {
                    printf("kiln-serve: detection ready [EXPERIMENTAL, unverified] (%s)\n", vc.vision_model.c_str());
                }
            } else {
                vision.reset(new KilnVision());
                if (vision->init(vc) != 0) {
                    fprintf(stderr, "kiln-serve: vision disabled (%s)\n", vision->error());
                    vision.reset();
                } else {
                    printf("kiln-serve: vision ready (%s)\n", vc.vision_model.c_str());
                }
            }
        }
    }

    if (!llm && !vision && !detector) {
        fprintf(stderr, "kiln-serve: neither an LLM (.rkllm) nor a vision (.rknn) model "
                        "was loadable. Check /etc/kiln/config.ini.\n");
        return 1;
    }
    printf("kiln-serve: ready [%s%s%s]. Listening on http://%s:%d  (OpenAI /v1)\n",
           llm ? "chat" : "",
           vision ? (llm ? "+classify" : "classify") : "",
           detector ? ((llm || vision) ? "+detect" : "detect") : "",
           cfg.server_host.c_str(), cfg.server_port);

    httplib::Server srv;

    srv.Get("/health", [](const httplib::Request &, httplib::Response &res) {
        res.set_content("{\"status\":\"ok\"}", "application/json");
    });

    srv.Get("/v1/models", [&](const httplib::Request &, httplib::Response &res) {
        json data = json::array();
        if (llm) {
            for (const auto &p : list_models(model_path)) {
                std::string n = p.substr(p.find_last_of('/') + 1);
                data.push_back({{"id", n}, {"object", "model"}, {"owned_by", "kiln"}});
            }
            if (data.empty())
                data.push_back({{"id", model_name}, {"object", "model"}, {"owned_by", "kiln"}});
        }
        res.set_content(json{{"object", "list"}, {"data", data}}.dump(), "application/json");
    });

    srv.Post("/v1/chat/completions", [&](const httplib::Request &req, httplib::Response &res) {
        if (!llm) {
            res.status = 503;
            res.set_content("{\"error\":\"no LLM on this box (vision-only, e.g. RK3568)\"}", "application/json");
            return;
        }
        json body;
        try { body = json::parse(req.body); }
        catch (...) { res.status = 400; res.set_content("{\"error\":\"invalid JSON\"}", "application/json"); return; }
        if (!body.contains("messages") || !body["messages"].is_array()) {
            res.status = 400; res.set_content("{\"error\":\"missing messages[]\"}", "application/json"); return;
        }
        bool stream = body.value("stream", false);
        std::string prompt = build_chatml(body["messages"], cfg.llm_system_prompt);
        std::string id = now_id("chatcmpl");
        long created = (long)time(nullptr);

        if (stream) {
            res.set_header("Cache-Control", "no-cache");
            res.set_chunked_content_provider(
                "text/event-stream",
                [&, prompt, id, created](size_t, httplib::DataSink &sink) {
                    auto send = [&](const json &j) {
                        std::string s = "data: " + j.dump() + "\n\n";
                        return sink.write(s.data(), s.size());
                    };
                    // first chunk: role
                    send({{"id", id}, {"object", "chat.completion.chunk"}, {"created", created},
                          {"model", model_name},
                          {"choices", {{{"index", 0}, {"delta", {{"role", "assistant"}}}, {"finish_reason", nullptr}}}}});
                    KilnRunCtx ctx;
                    ctx.on_token = [&](const char *tok) {
                        send({{"id", id}, {"object", "chat.completion.chunk"}, {"created", created},
                              {"model", model_name},
                              {"choices", {{{"index", 0}, {"delta", {{"content", tok}}}, {"finish_reason", nullptr}}}}});
                    };
                    llm->run(prompt, false, ctx);
                    // final chunk + [DONE]
                    send({{"id", id}, {"object", "chat.completion.chunk"}, {"created", created},
                          {"model", model_name},
                          {"choices", {{{"index", 0}, {"delta", json::object()}, {"finish_reason", "stop"}}}}});
                    std::string done = "data: [DONE]\n\n";
                    sink.write(done.data(), done.size());
                    sink.done();
                    return true;
                });
        } else {
            std::string full;
            KilnRunCtx ctx;
            ctx.on_token = [&](const char *tok) { full += tok; };
            llm->run(prompt, false, ctx);
            json out = {
                {"id", id}, {"object", "chat.completion"}, {"created", created},
                {"model", model_name},
                {"choices", {{{"index", 0},
                              {"message", {{"role", "assistant"}, {"content", full}}},
                              {"finish_reason", "stop"}}}},
                {"usage", {{"prompt_tokens", 0}, {"completion_tokens", ctx.ntok},
                           {"total_tokens", ctx.ntok}}}};
            res.set_content(out.dump(), "application/json");
        }
    });

    // Optional vision classify. Not an OpenAI standard, so a simple custom shape:
    // POST an image (raw body, or multipart field `file`); returns top-N classes.
    srv.Post("/v1/vision/classify", [&](const httplib::Request &req, httplib::Response &res) {
        if (!vision) {
            res.status = 503;
            res.set_content("{\"error\":\"vision not enabled (no .rknn model on this box)\"}", "application/json");
            return;
        }
        std::string img = req.has_file("file") ? req.get_file_value("file").content : req.body;
        if (img.empty()) {
            res.status = 400;
            res.set_content("{\"error\":\"no image; POST raw image bytes or multipart file=\"}", "application/json");
            return;
        }
        int top_n = req.has_param("top_n") ? atoi(req.get_param_value("top_n").c_str()) : cfg.vision_top_n;
        double ms = 0; std::string err;
        auto r = vision->classify_encoded((const unsigned char *)img.data(), (int)img.size(), top_n, &ms, &err);
        if (r.empty() && !err.empty()) {
            res.status = 400; res.set_content(json{{"error", err}}.dump(), "application/json"); return;
        }
        std::string vpath = cfg.server_vision();
        json top = json::array();
        for (const auto &x : r) top.push_back({{"index", x.index}, {"label", x.label}, {"score", x.score}});
        res.set_content(json{{"model", vpath.substr(vpath.find_last_of('/') + 1)},
                             {"inference_ms", ms}, {"top", top}}.dump(), "application/json");
    });

    // EXPERIMENTAL object detection (config [vision] task = detect; YOLOv8/11).
    // Same custom shape as classify: POST an image, get a list of boxes. UNVERIFIED
    // on hardware -- boxes may be wrong. Disabled unless a detector loaded.
    srv.Post("/v1/vision/detect", [&](const httplib::Request &req, httplib::Response &res) {
        if (!detector) {
            res.status = 503;
            res.set_content("{\"error\":\"detection not enabled (set [vision] task=detect with a YOLOv8/11 .rknn)\"}", "application/json");
            return;
        }
        std::string img = req.has_file("file") ? req.get_file_value("file").content : req.body;
        if (img.empty()) {
            res.status = 400;
            res.set_content("{\"error\":\"no image; POST raw image bytes or multipart file=\"}", "application/json");
            return;
        }
        float conf = req.has_param("conf") ? (float)atof(req.get_param_value("conf").c_str()) : cfg.vision_conf;
        float iou  = req.has_param("iou")  ? (float)atof(req.get_param_value("iou").c_str())  : cfg.vision_nms_iou;
        double ms = 0; std::string err;
        auto dets = detector->detect_encoded((const unsigned char *)img.data(), (int)img.size(), conf, iou, &ms, &err);
        if (dets.empty() && !err.empty()) {
            res.status = 400; res.set_content(json{{"error", err}}.dump(), "application/json"); return;
        }
        std::string vpath = cfg.server_vision();
        json objs = json::array();
        for (const auto &o : dets)
            objs.push_back({{"class_id", o.class_id}, {"label", o.label}, {"score", o.score},
                            {"box", {o.box.x1, o.box.y1, o.box.x2, o.box.y2}}});
        res.set_content(json{{"model", vpath.substr(vpath.find_last_of('/') + 1)},
                             {"experimental", true}, {"inference_ms", ms}, {"objects", objs}}.dump(), "application/json");
    });

    if (!srv.listen(cfg.server_host.c_str(), cfg.server_port)) {
        fprintf(stderr, "kiln-serve: failed to bind %s:%d\n", cfg.server_host.c_str(), cfg.server_port);
        return 1;
    }
    return 0;
}
