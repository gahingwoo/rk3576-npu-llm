// SPDX-License-Identifier: Apache-2.0
// kiln_config.h -- one config for the whole Kiln stack (kiln-chat, kiln-vision,
// kiln-serve). Tiny INI reader/writer, no dependency. All three binaries read
// the SAME file (default /etc/kiln/config.ini, override with $KILN_CONFIG) so
// nothing is hard-coded per tool. Edit it by hand; kiln-chat can also change the
// LLM knobs live via slash commands (/model, /system, /history).
//
// Only fields the closed runtimes actually expose are here:
//   LLM  (librkllmrt): model, context/new-tokens, sampling, system prompt,
//                      embed_flash, CPU mask, KV-cache keep_history / n_keep.
//   Vision (librknnrt): model, labels, top-N, NPU core mask, priority.
//   (Vision mean/std + input size are BAKED INTO the .rknn at conversion --
//    not runtime-settable -- so they are deliberately absent.)
#pragma once
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>

struct KilnConfig {
    // [llm] -- librkllmrt RKLLMParam / APIs.
    // Empty by default: Kiln ships no model and does not hard-code one. The tools
    // AUTO-DISCOVER a *.rkllm in /opt/models when this is empty or the file is
    // missing (see kiln::resolve_model). Set a path to pin a specific model.
    std::string llm_model            = "";
    int         llm_max_context_len  = 2048;
    int         llm_max_new_tokens   = 512;
    int         llm_top_k            = 1;     // greedy: most coherent on the 1.5B w4a16
    float       llm_top_p            = 0.8f;  // model (sampling makes it hallucinate off-
    float       llm_temperature      = 0.7f;  // topic). Clean stop comes from kiln_is_stop_id,
                                              // not from the sampling, so greedy is safe now.
    float       llm_repeat_penalty   = 1.3f;   // break greedy repetition loops on the small model
    float       llm_frequency_penalty= 0.0f;
    float       llm_presence_penalty = 0.0f;
    int         llm_embed_flash      = 1;    // query word-embeddings from flash
    int         llm_keep_history     = 1;    // 1 = multi-turn KV retained (default), 0 = single-turn
    int         llm_n_keep           = -1;   // KV tokens kept on context shift; -1 = runtime default
    // system-prompt CONTENT (single line); kiln_llm wraps it in the model's chat
    // markers. Empty by default -- no system prompt, so the model behaves as-is
    // (model-neutral; set one live with /system, or here).
    std::string llm_system_prompt    = "";

    // [vision] -- librknnrt. Empty by default: auto-discover a *.rknn in /opt/models
    // (like the LLM). NB a .rknn can be a classifier OR a detector, so with several
    // present, PIN the right one per task (kiln-config -> Vision -> model).
    std::string vision_model   = "";
    std::string vision_labels  = "/opt/models/imagenet_labels.txt";
    int         vision_top_n   = 5;
    std::string vision_core_mask = "auto";  // auto | 0 | 1 | 0_1   (RK3576 has 2 NPU cores)
    std::string vision_priority  = "high";  // high | medium | low
    // detection knobs -- only used when task = detect (EXPERIMENTAL YOLOv8/11; the
    // default classify path ignores them). See kiln_detect.h / docs/VISION.md.
    std::string vision_task      = "classify"; // classify | detect
    std::string vision_detector  = "auto";     // auto | yolov8 | yolov5 | yolox
    float       vision_conf      = 0.25f;      // detection score threshold
    float       vision_nms_iou   = 0.45f;      // detection NMS IoU threshold

    // [server] -- kiln-serve
    std::string server_host  = "0.0.0.0";
    int         server_port  = 8080;
    // "" -> fall back to llm_model / vision_model above
    std::string server_llm_model    = "";
    std::string server_vision_model = "";

    std::string llm_model_effective() const { return llm_model; }
    std::string server_llm() const    { return server_llm_model.empty()    ? llm_model    : server_llm_model; }
    std::string server_vision() const { return server_vision_model.empty() ? vision_model : server_vision_model; }
};

namespace kiln {

inline std::string config_path() {
    const char *e = getenv("KILN_CONFIG");
    return e && *e ? std::string(e) : std::string("/etc/kiln/config.ini");
}

inline bool file_exists(const std::string &p) {
    if (p.empty()) return false;
    FILE *f = fopen(p.c_str(), "rb"); if (!f) return false; fclose(f); return true;
}
inline std::string dir_of(const std::string &p) {
    size_t s = p.find_last_of('/');
    return s == std::string::npos ? std::string(".") : p.substr(0, s);
}
// Return dir + "/" + <first file ending in `ext`, name-sorted>, or "" if none.
inline std::string first_model(const std::string &dir, const char *ext) {
    DIR *d = opendir(dir.c_str()); if (!d) return "";
    std::vector<std::string> names; std::string e = ext;
    for (dirent *de; (de = readdir(d)); ) {
        std::string n = de->d_name;
        if (n.size() > e.size() && n.compare(n.size() - e.size(), e.size(), e) == 0) names.push_back(n);
    }
    closedir(d);
    if (names.empty()) return "";
    std::sort(names.begin(), names.end());
    return dir + "/" + names[0];
}
// Resolve a model path: use `configured` if it exists; otherwise AUTO-DISCOVER a
// *ext file (in `configured`'s dir when set, else in `fallback_dir`). Returns "" if
// nothing is found. This is how Kiln avoids hard-coding a model name.
inline std::string resolve_model(const std::string &configured, const char *ext,
                                 const std::string &fallback_dir = "/opt/models") {
    if (file_exists(configured)) return configured;
    std::string dir = configured.empty() ? fallback_dir : dir_of(configured);
    std::string m = first_model(dir, ext);
    if (m.empty() && dir != fallback_dir) m = first_model(fallback_dir, ext);
    return m;
}

inline std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// Load config from `path` into `c`. Missing file / missing keys keep defaults,
// so a fresh box works before any config file is written. Returns true if the
// file existed and was read.
inline bool load(KilnConfig &c, const std::string &path = config_path()) {
    std::ifstream f(path);
    if (!f) return false;
    std::string line, section;
    while (std::getline(f, line)) {
        std::string t = trim(line);
        if (t.empty() || t[0] == '#' || t[0] == ';') continue;
        if (t[0] == '[') { section = trim(t.substr(1, t.find(']') - 1)); continue; }
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trim(t.substr(0, eq));
        std::string v = t.substr(eq + 1);
        // Strip a trailing INLINE comment (whitespace then '#'). save() writes such
        // comments on the enum fields ("core_mask = auto   # auto | 0 | 1 | 0_1"),
        // so without this a persisted non-default value like "core_mask = 0   # ..."
        // would be read as the literal "0   # ..." and never match. This matches the
        // shell tools' reader (kiln-doctor / kiln-config). NB: a '#' that follows a
        // space inside a value (an unusual system_prompt) is treated as a comment --
        // avoid " #" in a system prompt.
        {
            size_t hs = v.find(" #"), ht = v.find("\t#");
            if (ht != std::string::npos && (hs == std::string::npos || ht < hs)) hs = ht;
            if (hs != std::string::npos) v = v.substr(0, hs);
        }
        v = trim(v);
        std::string key = section + "." + k;
        // LLM
        if      (key == "llm.model")             c.llm_model = v;
        else if (key == "llm.max_context_len")   c.llm_max_context_len = atoi(v.c_str());
        else if (key == "llm.max_new_tokens")    c.llm_max_new_tokens = atoi(v.c_str());
        else if (key == "llm.top_k")             c.llm_top_k = atoi(v.c_str());
        else if (key == "llm.top_p")             c.llm_top_p = (float)atof(v.c_str());
        else if (key == "llm.temperature")       c.llm_temperature = (float)atof(v.c_str());
        else if (key == "llm.repeat_penalty")    c.llm_repeat_penalty = (float)atof(v.c_str());
        else if (key == "llm.frequency_penalty") c.llm_frequency_penalty = (float)atof(v.c_str());
        else if (key == "llm.presence_penalty")  c.llm_presence_penalty = (float)atof(v.c_str());
        else if (key == "llm.embed_flash")       c.llm_embed_flash = atoi(v.c_str());
        else if (key == "llm.keep_history")      c.llm_keep_history = atoi(v.c_str());
        else if (key == "llm.n_keep")            c.llm_n_keep = atoi(v.c_str());
        else if (key == "llm.system_prompt")     c.llm_system_prompt = v;
        // Vision
        else if (key == "vision.model")          c.vision_model = v;
        else if (key == "vision.labels")         c.vision_labels = v;
        else if (key == "vision.top_n")          c.vision_top_n = atoi(v.c_str());
        else if (key == "vision.core_mask")      c.vision_core_mask = v;
        else if (key == "vision.priority")       c.vision_priority = v;
        else if (key == "vision.task")           c.vision_task = v;
        else if (key == "vision.detector")       c.vision_detector = v;
        else if (key == "vision.conf_threshold") c.vision_conf = (float)atof(v.c_str());
        else if (key == "vision.nms_iou")        c.vision_nms_iou = (float)atof(v.c_str());
        // Server
        else if (key == "server.host")           c.server_host = v;
        else if (key == "server.port")           c.server_port = atoi(v.c_str());
        else if (key == "server.llm_model")      c.server_llm_model = v;
        else if (key == "server.vision_model")   c.server_vision_model = v;
    }
    return true;
}

inline bool save(const KilnConfig &c, const std::string &path = config_path()) {
    std::ofstream f(path);
    if (!f) return false;
    f << "# Kiln unified config -- read by kiln-chat, kiln-vision, kiln-serve.\n"
         "# Edit by hand; kiln-chat can also change the LLM knobs live (/help). Only runtime-settable fields.\n\n";
    f << "[llm]\n";
    f << "model = "             << c.llm_model << "\n";
    f << "max_context_len = "   << c.llm_max_context_len << "\n";
    f << "max_new_tokens = "    << c.llm_max_new_tokens << "\n";
    f << "top_k = "             << c.llm_top_k << "\n";
    f << "top_p = "             << c.llm_top_p << "\n";
    f << "temperature = "       << c.llm_temperature << "\n";
    f << "repeat_penalty = "    << c.llm_repeat_penalty << "\n";
    f << "frequency_penalty = " << c.llm_frequency_penalty << "\n";
    f << "presence_penalty = "  << c.llm_presence_penalty << "\n";
    f << "embed_flash = "       << c.llm_embed_flash << "\n";
    f << "keep_history = "      << c.llm_keep_history << "   # 1 = multi-turn (KV retained), 0 = single-turn\n";
    f << "n_keep = "            << c.llm_n_keep << "        # KV tokens kept on context shift; -1 = default\n";
    f << "system_prompt = "     << c.llm_system_prompt << "\n\n";
    f << "[vision]\n";
    f << "model = "             << c.vision_model << "\n";
    f << "labels = "            << c.vision_labels << "\n";
    f << "top_n = "             << c.vision_top_n << "\n";
    f << "core_mask = "         << c.vision_core_mask << "   # auto | 0 | 1 | 0_1\n";
    f << "priority = "          << c.vision_priority << "     # high | medium | low\n";
    f << "task = "              << c.vision_task << "     # classify | detect (detect = EXPERIMENTAL)\n";
    f << "detector = "          << c.vision_detector << "         # auto | yolov8 | yolov5 | yolox (task=detect)\n";
    f << "conf_threshold = "    << c.vision_conf << "   # detection score threshold (task=detect)\n";
    f << "nms_iou = "           << c.vision_nms_iou << "        # detection NMS IoU (task=detect)\n\n";
    f << "[server]\n";
    f << "host = "              << c.server_host << "\n";
    f << "port = "              << c.server_port << "\n";
    f << "llm_model = "         << c.server_llm_model << "     # blank = use [llm] model\n";
    f << "vision_model = "      << c.server_vision_model << "  # blank = use [vision] model\n";
    return true;
}

} // namespace kiln
