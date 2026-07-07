// SPDX-License-Identifier: Apache-2.0
// kiln-serve -- an OpenAI-compatible HTTP API for the LLM running on the RK3576
// NPU (librkllmrt). It wraps the SAME RKLLM call sequence as kiln-chat (via
// kiln_llm.h), so nothing about inference is re-implemented -- only an HTTP +
// SSE layer on top. Config comes from the unified /etc/kiln/config.ini.
//
//   GET  /v1/models            list the .rkllm model(s)
//   POST /v1/chat/completions  OpenAI chat; `stream:true` -> SSE token stream
//   GET  /health               liveness
//
// The model is loaded once at startup (rkllm_init is heavy: it maps the whole
// model). The NPU is single-tenant, so requests are serialized in kiln_llm.
// Build: needs httplib.h (cpp-httplib) + json.hpp (nlohmann/json), both
// header-only, fetched by buildroot/fetch-runtimes.sh. No runtime deps beyond
// librkllmrt + libgomp.
#include "httplib.h"
#include "json.hpp"
#include "kiln_config.h"
#include "kiln_llm.h"

#include <atomic>
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

    const std::string model_path = cfg.server_llm();
    const std::string model_name = model_path.substr(model_path.find_last_of('/') + 1);

    printf("kiln-serve: loading %s onto the NPU ...\n", model_path.c_str());
    KilnConfig lc = cfg;
    lc.llm_model = model_path;
    KilnLLM llm;
    int ret = llm.init(lc);
    if (ret != 0) {
        fprintf(stderr, "kiln-serve: rkllm_init failed (%d). Check the .rkllm path/model.\n", ret);
        return 1;
    }
    // Pass-through template: we hand the runtime a fully-formed ChatML string.
    llm.set_chat_template("", "", "");
    printf("kiln-serve: model ready. Listening on http://%s:%d  (OpenAI /v1)\n",
           cfg.server_host.c_str(), cfg.server_port);

    httplib::Server srv;

    srv.Get("/health", [](const httplib::Request &, httplib::Response &res) {
        res.set_content("{\"status\":\"ok\"}", "application/json");
    });

    srv.Get("/v1/models", [&](const httplib::Request &, httplib::Response &res) {
        json data = json::array();
        for (const auto &p : list_models(model_path)) {
            std::string n = p.substr(p.find_last_of('/') + 1);
            data.push_back({{"id", n}, {"object", "model"}, {"owned_by", "kiln"}});
        }
        if (data.empty())
            data.push_back({{"id", model_name}, {"object", "model"}, {"owned_by", "kiln"}});
        res.set_content(json{{"object", "list"}, {"data", data}}.dump(), "application/json");
    });

    srv.Post("/v1/chat/completions", [&](const httplib::Request &req, httplib::Response &res) {
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
                    llm.run(prompt, false, ctx);
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
            llm.run(prompt, false, ctx);
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

    if (!srv.listen(cfg.server_host.c_str(), cfg.server_port)) {
        fprintf(stderr, "kiln-serve: failed to bind %s:%d\n", cfg.server_host.c_str(), cfg.server_port);
        return 1;
    }
    return 0;
}
