// Kiln: interactive chat with an LLM on the RK3576 NPU (librkllmrt).
//
// Config-driven (kiln_llm.h + kiln_config.h): model, context, sampling, system
// prompt and KV-cache history come from /etc/kiln/config.ini. The RKLLM call
// sequence is unchanged -- it lives in kiln_llm.h so kiln-serve reuses it.
//
// Slash commands manage the session (type /help). Anything not starting with
// '/' is sent to the model. The commands are a thin dispatch layer around the
// same generate() call; they do not change the inference path.
//
// Usage:
//   rkllm_chat                                  # all from config
//   rkllm_chat <model.rkllm> [new_tokens] [ctx] # explicit override (old form)
#include "kiln_llm.h"
#include "kiln_config.h"
#include <cstdio>
#include <string>
#include <vector>
#include <sstream>
#include <algorithm>
#include <iostream>
#include <chrono>
#include <csignal>
#include <dirent.h>
#include <sys/stat.h>

// ---- small helpers ---------------------------------------------------------

static std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static std::string dir_of(const std::string &path) {
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? "." : path.substr(0, slash);
}
static std::string base_of(const std::string &path) {
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

// List *.rkllm files in a directory (sorted). Lightweight: POSIX dirent, no
// <filesystem> so the buildroot toolchain needs no extra link.
static std::vector<std::string> list_models(const std::string &dir) {
    std::vector<std::string> out;
    DIR *d = opendir(dir.c_str());
    if (!d) return out;
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        std::string n = e->d_name;
        if (n.size() > 6 && n.substr(n.size() - 6) == ".rkllm") out.push_back(n);
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// ---- one generation, streamed --------------------------------------------

struct GenResult { std::string text; long ntok = 0; double ttft = -1; double total = 0; bool error = false; };

// Run one prompt. echo=true streams tokens to stdout (a normal turn); echo=false
// stays silent and just captures the text (used by /compact's summary pass).
static GenResult generate(KilnLLM &llm, const std::string &prompt, bool keep_history, bool echo) {
    GenResult r;
    auto t0 = std::chrono::steady_clock::now();
    KilnRunCtx ctx;
    ctx.on_token = [&](const char *tok) {
        if (r.ntok == 0)
            r.ttft = std::chrono::duration<double, std::milli>(
                         std::chrono::steady_clock::now() - t0).count();
        r.ntok++;
        r.text += tok;
        if (echo) { printf("%s", tok); fflush(stdout); }
    };
    try {
        llm.run(prompt, keep_history, ctx);
    } catch (const std::exception &e) {
        r.error = true;
        if (echo) printf("\n[error] generation failed: %s -- try rephrasing.\n", e.what());
    } catch (...) {
        r.error = true;
        if (echo) printf("\n[error] generation failed (unknown) -- try rephrasing.\n");
    }
    r.total = std::chrono::duration<double, std::milli>(
                  std::chrono::steady_clock::now() - t0).count();
    return r;
}

// ---- session state the commands act on ------------------------------------

struct ChatState {
    long turns = 0;          // conversation turns since the last clear/new/compact
    long gen_tokens = 0;     // tokens the model has generated since then
    std::string base_system; // the configured system prompt (before any /compact summary)
    std::string model_dir;   // where /model looks for *.rkllm
};

static void print_help() {
    printf("Commands (anything else is sent to the model):\n"
           "  /help            show this list\n"
           "  /clear           forget the conversation, keep the system prompt\n"
           "  /new             start a fresh session (clear + reset)\n"
           "  /history [on|off] multi-turn memory on/off (no arg: show)\n"
           "  /system [text]   show or set the system prompt (resets the session)\n"
           "  /context         show the context window and what is in use\n"
           "  /compact         summarize the conversation to free up context\n"
           "  /model [name]    list models, or switch to one (reloads, takes a few s)\n"
           "  /exit, /quit     leave\n");
}

// Returns true to keep looping, false to quit.
static bool handle_command(const std::string &line, KilnLLM &llm, KilnConfig &cfg, ChatState &st) {
    std::istringstream iss(line);
    std::string cmd; iss >> cmd;
    std::string arg; std::getline(iss, arg); arg = trim(arg);

    if (cmd == "/exit" || cmd == "/quit") return false;

    if (cmd == "/help") { print_help(); return true; }

    if (cmd == "/clear") {
        llm.clear_kv_cache(1);           // keep the system prompt in the KV
        st.turns = 0; st.gen_tokens = 0;
        printf("[conversation cleared; system prompt kept]\n");
        return true;
    }

    if (cmd == "/new") {
        llm.set_system_prompt(st.base_system);  // re-applies template + clears KV
        st.turns = 0; st.gen_tokens = 0;
        printf("[new session]\n");
        return true;
    }

    if (cmd == "/history") {
        if (arg.empty()) {
            printf("history: %s\n", cfg.llm_keep_history ? "on (multi-turn)" : "off (single-turn)");
        } else if (arg == "on")  { cfg.llm_keep_history = 1; printf("[history on -- the model now remembers the conversation]\n"); }
        else if (arg == "off") { cfg.llm_keep_history = 0; llm.clear_kv_cache(1); st.turns = 0; st.gen_tokens = 0;
                                   printf("[history off -- each turn is independent]\n"); }
        else printf("usage: /history [on|off]\n");
        return true;
    }

    if (cmd == "/system") {
        if (arg.empty()) { printf("system prompt: %s\n", st.base_system.c_str()); return true; }
        st.base_system = arg;
        cfg.llm_system_prompt = arg;
        llm.set_system_prompt(arg);
        st.turns = 0; st.gen_tokens = 0;
        printf("[system prompt set; session reset]\n");
        return true;
    }

    if (cmd == "/context") {
        // The runtime does not expose live KV token usage or a tokenizer, so we
        // report the window size and what we can count exactly (turns + tokens
        // the model generated); prompt tokens are not observable from here.
        printf("context window: %d tokens\n", cfg.llm_max_context_len);
        printf("history: %s | turns: %ld | generated tokens: %ld\n",
               cfg.llm_keep_history ? "on" : "off", st.turns, st.gen_tokens);
        printf("(prompt-side token usage is not exposed by the runtime; use /compact if replies degrade)\n");
        return true;
    }

    if (cmd == "/compact") {
        if (st.turns == 0) { printf("[nothing to compact]\n"); return true; }
        printf("[compacting: asking the model to summarize the conversation ...]\n");
        fflush(stdout);
        GenResult s = generate(llm,
            "Summarize our conversation so far in 3-4 sentences, keeping the key "
            "facts and context, so it can be used to continue.",
            /*keep_history*/true, /*echo*/false);
        std::string summary = trim(s.text);
        if (s.error || summary.empty()) { printf("[compact failed; conversation left as-is]\n"); return true; }
        // Fold the summary into the system prompt and clear the KV. This is an
        // application-level approximation: the runtime has no KV compaction, so
        // it costs one extra inference and the long history becomes this summary.
        llm.set_system_prompt(st.base_system + "\n\nSummary of the earlier conversation: " + summary);
        st.turns = 0; st.gen_tokens = 0;
        printf("[compacted -- earlier turns replaced by this summary (app-level, cost 1 inference):]\n%s\n",
               summary.c_str());
        return true;
    }

    if (cmd == "/model") {
        std::vector<std::string> models = list_models(st.model_dir);
        if (arg.empty()) {
            if (models.empty()) { printf("no .rkllm models in %s\n", st.model_dir.c_str()); return true; }
            printf("models in %s:\n", st.model_dir.c_str());
            for (const auto &m : models)
                printf("  %s%s\n", m.c_str(), (base_of(cfg.llm_model) == m) ? "  (current)" : "");
            printf("switch with: /model <name>\n");
            return true;
        }
        // resolve arg -> path (accept a bare name in model_dir or a full path)
        std::string path = (arg.find('/') != std::string::npos) ? arg : st.model_dir + "/" + arg;
        if (!file_exists(path)) { printf("[not found: %s]\n", path.c_str()); return true; }
        printf("[loading %s ... this takes a few seconds]\n", base_of(path).c_str());
        fflush(stdout);
        KilnConfig ncfg = cfg;
        ncfg.llm_model = path;
        if (llm.reinit(ncfg) != 0) {
            printf("[failed to load %s -- keeping the current model]\n", base_of(path).c_str());
            // best-effort: bring the previous model back
            llm.reinit(cfg);
            return true;
        }
        cfg = ncfg;
        st.turns = 0; st.gen_tokens = 0;
        st.model_dir = dir_of(cfg.llm_model);
        printf("[loaded %s]\n", base_of(cfg.llm_model).c_str());
        return true;
    }

    printf("unknown command '%s' -- type /help\n", cmd.c_str());
    return true;
}

// ---- REPL ------------------------------------------------------------------

static KilnLLM *g_llm = nullptr;
static void on_sigint(int) { printf("\nExiting ...\n"); exit(0); }

int main(int argc, char **argv) {
    KilnConfig cfg;
    kiln::load(cfg);
    // old form: <model> [max_new_tokens] [max_context_len] overrides config
    if (argc > 1) cfg.llm_model = argv[1];
    if (argc > 2) cfg.llm_max_new_tokens = atoi(argv[2]);
    if (argc > 3) cfg.llm_max_context_len = atoi(argv[3]);

    signal(SIGINT, on_sigint);
    printf("rkllm init start\n");

    KilnLLM llm;
    g_llm = &llm;
    if (llm.init(cfg) != 0) { printf("rkllm init failed\n"); return -1; }
    printf("rkllm init success\n");

    ChatState st;
    st.base_system = cfg.llm_system_prompt;
    st.model_dir   = dir_of(cfg.llm_model);

    printf("=== Kiln RK3576 NPU LLM (librkllmrt) ===\n");
    printf("model: %s | history: %s\n", base_of(cfg.llm_model).c_str(),
           cfg.llm_keep_history ? "multi-turn" : "single-turn");
    printf("Type a message, or /help for commands.\n");

    while (true) {
        std::string input;
        printf("\nuser: ");
        if (!std::getline(std::cin, input)) break;
        input = trim(input);
        if (input.empty()) continue;

        if (input[0] == '/') {
            if (!handle_command(input, llm, cfg, st)) break;
            continue;
        }

        printf("robot: ");
        fflush(stdout);
        GenResult r = generate(llm, input, cfg.llm_keep_history != 0, /*echo*/true);
        if (r.error) continue;
        st.turns++;
        st.gen_tokens += r.ntok;

        double decode_ms = r.total - (r.ttft < 0 ? 0 : r.ttft);
        double tps = (r.ntok > 1 && decode_ms > 0) ? (r.ntok - 1) * 1000.0 / decode_ms : 0.0;
        printf("\n[bench] tokens=%ld  prefill(TTFT)=%.0f ms  decode=%.1f tok/s  total=%.0f ms\n",
               r.ntok, r.ttft < 0 ? 0.0 : r.ttft, tps, r.total);
    }
    return 0;
}
