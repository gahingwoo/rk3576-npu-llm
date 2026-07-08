// SPDX-License-Identifier: Apache-2.0
// kiln_llm.h -- thin wrapper around librkllmrt that both kiln-chat (CLI) and
// kiln-serve (HTTP) use, so the RKLLM call sequence lives in ONE place and the
// inference logic is reused, not rewritten. It is the exact sequence from the
// original rkllm_chat.cpp (createDefaultParam -> set fields -> rkllm_init ->
// set_chat_template -> rkllm_run), just driven from KilnConfig and streaming
// tokens through a per-request callback instead of straight to stdout.
//
// The NPU/runtime handles one generation at a time, so run() is serialized with
// a mutex -- callers (e.g. the HTTP server) can invoke it from any thread.
#pragma once
#include <cstdint>   // rkllm.h uses int32_t/int8_t/size_t but includes neither
#include <cstddef>
#include "rkllm.h"
#include "kiln_config.h"
#include <functional>
#include <string>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <mutex>

// Per-run routing context handed to the C callback via rkllm_run()'s userdata.
struct KilnRunCtx {
    std::function<void(const char *token)> on_token; // one decoded token chunk
    std::function<void(bool had_error)> on_finish;   // generation ended
    long ntok = 0;
    std::function<void()> request_abort;             // set by run(); stops generation
    bool stopped = false;                            // a stop token was seen
    char last_ch = '\n';                             // last char emitted (for stop sequences)
};

// The small model often fails to end its turn and instead role-plays a fresh
// one -- e.g. "...requirements?\n\nAssistant: No problem ...". A role label at the
// start of a line is that drift, so we treat it as an end-of-turn stop sequence.
static inline bool kiln_is_role_label(const std::string &s) {
    return s == "Assistant" || s == "User" || s == "Human" || s == "System" ||
           s == "assistant" || s == "user" || s == "human" || s == "system";
}

// Turn/END token IDs, by family (this RKLLM build may not flag them special, so
// it neither stops nor skips them -- it detokenizes them to ordinary text and
// runs to max_new_tokens; stopping on the ID is decoding-independent). The two
// families' IDs do not overlap, so a union check is safe across models:
//   Qwen2.5 ChatML : <|endoftext|>=151643, <|im_end|>=151645
//   Llama-3        : <|end_of_text|>=128001, <|eot_id|>=128009
// Confirm on hardware with KILN_DEBUG_TOKENS=1.
static inline bool kiln_is_stop_id(int32_t id) {
    return id == 151643 || id == 151645 || id == 128001 || id == 128009;
}

// Text fallback, in case a build DOES decode a marker to a string.
static const char *const KILN_STOP_MARKERS[] = {
    "<|im_end|>", "<|endoftext|>", "<|im_start|>", "<|eot_id|>", "<|end_of_text|>", "<|start_header_id|>"
};

// Single C callback for rkllm_init; routes each result to the run's context.
static void kiln_llm_callback(RKLLMResult *result, void *userdata, LLMCallState state) {
    KilnRunCtx *ctx = static_cast<KilnRunCtx *>(userdata);
    if (state == RKLLM_RUN_NORMAL) {
        if (!ctx || !result || ctx->stopped) return;
        static const bool dbg = getenv("KILN_DEBUG_TOKENS") != nullptr;
        if (dbg) fprintf(stderr, "\n[tok id=%d \"%s\"]", result->token_id,
                         result->text ? result->text : "");
        // Primary stop: the turn-terminator token ID (robust to mis-decoding).
        if (kiln_is_stop_id(result->token_id)) {
            ctx->stopped = true;
            if (ctx->request_abort) ctx->request_abort();
            if (ctx->on_finish) ctx->on_finish(false);
            return;
        }
        if (!result->text) return;
        std::string t = result->text;
        size_t cut = std::string::npos;   // fallback: marker decoded to text
        for (const char *m : KILN_STOP_MARKERS) {
            size_t p = t.find(m);
            if (p != std::string::npos && p < cut) cut = p;
        }
        if (cut != std::string::npos) {
            if (cut > 0 && ctx->on_token) { ctx->ntok++; ctx->on_token(t.substr(0, cut).c_str()); }
            ctx->stopped = true;
            if (ctx->request_abort) ctx->request_abort();
            if (ctx->on_finish) ctx->on_finish(false);
            return;
        }
        // Stop sequence: a role label at the start of a line = the model drifting
        // into a fake next turn. Trim it (do not emit) and end the turn.
        {
            size_t a = t.find_first_not_of(" \t");
            size_t b = t.find_last_not_of(" \t\r\n");
            std::string core = (a == std::string::npos) ? "" : t.substr(a, b - a + 1);
            if (ctx->last_ch == '\n' && kiln_is_role_label(core)) {
                ctx->stopped = true;
                if (ctx->request_abort) ctx->request_abort();
                if (ctx->on_finish) ctx->on_finish(false);
                return;
            }
        }
        ctx->ntok++;
        if (ctx->on_token) ctx->on_token(t.c_str());
        if (!t.empty()) ctx->last_ch = t[t.size() - 1];
    } else if (state == RKLLM_RUN_FINISH) {
        if (ctx && !ctx->stopped && ctx->on_finish) ctx->on_finish(false);
    } else if (state == RKLLM_RUN_ERROR) {
        if (ctx && ctx->on_finish) ctx->on_finish(true);
    }
}

class KilnLLM {
public:
    // init the runtime from config. Returns 0 on success (rkllm_init's code).
    int init(const KilnConfig &cfg) {
        cfg_ = cfg;
        RKLLMParam param = rkllm_createDefaultParam();
        param.model_path        = model_.assign(cfg.llm_model).c_str();
        param.max_context_len   = cfg.llm_max_context_len;
        param.max_new_tokens    = cfg.llm_max_new_tokens;
        param.top_k             = cfg.llm_top_k;
        param.top_p             = cfg.llm_top_p;
        param.temperature       = cfg.llm_temperature;
        param.repeat_penalty    = cfg.llm_repeat_penalty;
        param.frequency_penalty = cfg.llm_frequency_penalty;
        param.presence_penalty  = cfg.llm_presence_penalty;
        if (cfg.llm_n_keep >= 0) param.n_keep = cfg.llm_n_keep;
        // Hide special tokens from output; stopping is handled by token ID in the
        // callback (kiln_is_stop_id), which works even though this build mis-decodes
        // <|im_end|> as ordinary text instead of treating it as special.
        param.skip_special_token = true;
        param.extend_param.base_domain_id = 0;
        param.extend_param.embed_flash    = (int8_t)cfg.llm_embed_flash;

        int ret = rkllm_init(&h_, &param, kiln_llm_callback);
        if (ret != 0) return ret;

        apply_chat_template(cfg.llm_system_prompt);
        return 0;
    }

    // Reload a different model at runtime (/model switch). Destroys the current
    // handle and re-inits from cfg -- the caller warns the user about the load
    // delay. Returns rkllm_init's code (0 on success). CLI-only (single thread).
    int reinit(const KilnConfig &cfg) {
        { std::lock_guard<std::mutex> lk(mu_); if (h_) { rkllm_destroy(h_); h_ = nullptr; } }
        return init(cfg);
    }

    // Replace the system prompt at runtime (/system). Re-applies the ChatML
    // template with the new content and clears the KV cache so the old system
    // prompt is dropped and the new one takes effect from a fresh context.
    void set_system_prompt(const std::string &sys) {
        std::lock_guard<std::mutex> lk(mu_);
        cfg_.llm_system_prompt = sys;
        if (h_) { apply_chat_template(sys); rkllm_clear_kv_cache(h_, 0); }
    }

    // Generate for one prompt. keep_history overrides the config default (the
    // server passes it per request so /v1/chat/completions can be multi-turn).
    // Blocks until generation finishes; tokens arrive on ctx.on_token.
    int run(const std::string &prompt, bool keep_history, KilnRunCtx &ctx) {
        std::lock_guard<std::mutex> lk(mu_);
        ctx.request_abort = [this]{ if (h_) rkllm_abort(h_); };
        RKLLMInput input;
        memset(&input, 0, sizeof(input));
        input.input_type = RKLLM_INPUT_PROMPT;
        input.prompt_input = prompt.c_str();

        RKLLMInferParam ip;
        memset(&ip, 0, sizeof(ip));
        ip.mode = RKLLM_INFER_GENERATE;
        ip.keep_history = keep_history ? 1 : 0;
        return rkllm_run(h_, &input, &ip, &ctx);
    }

    void clear_kv_cache(int keep_system_prompt) {
        std::lock_guard<std::mutex> lk(mu_);
        if (h_) rkllm_clear_kv_cache(h_, keep_system_prompt);
    }

    // Override the chat template. kiln-serve sets it pass-through ("","","") and
    // feeds a fully-formatted ChatML string built from the OpenAI messages array,
    // so the server is stateless (the client resends history each request) and
    // OpenAI-correct, rather than relying on the runtime's per-turn KV history.
    void set_chat_template(const std::string &system,
                           const std::string &prefix,
                           const std::string &postfix) {
        std::lock_guard<std::mutex> lk(mu_);
        if (h_) rkllm_set_chat_template(h_, system.c_str(), prefix.c_str(), postfix.c_str());
    }

    bool ok() const { return h_ != nullptr; }
    const KilnConfig &config() const { return cfg_; }

    ~KilnLLM() { if (h_) rkllm_destroy(h_); }

private:
    // Install the chat template for the loaded model with the given system-prompt
    // CONTENT. The MARKERS are the model's format and must match the model, or it
    // drifts / mis-stops; only the content is user-facing. Family is picked from
    // the model filename (Llama uses header-id/eot markers, Qwen/default ChatML).
    // Not locked -- callers that need the mutex take it themselves; init() runs
    // before any threads.
    void apply_chat_template(const std::string &sys) {
        std::string lower = cfg_.llm_model;
        for (char &c : lower) c = (char)tolower((unsigned char)c);
        std::string system, prefix, postfix;
        if (lower.find("llama") != std::string::npos) {           // Llama-3 format
            system  = "<|start_header_id|>system<|end_header_id|>\n\n" + sys + "<|eot_id|>";
            prefix  = "<|start_header_id|>user<|end_header_id|>\n\n";
            postfix = "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n";
        } else {                                                  // Qwen / default ChatML
            system  = "<|im_start|>system\n" + sys + "<|im_end|>\n";
            prefix  = "<|im_start|>user\n";
            postfix = "<|im_end|>\n<|im_start|>assistant\n";
        }
        rkllm_set_chat_template(h_, system.c_str(), prefix.c_str(), postfix.c_str());
    }

    LLMHandle h_ = nullptr;
    KilnConfig cfg_;
    std::string model_;   // backs param.model_path across init()
    std::mutex mu_;       // NPU is single-tenant: one generation at a time
};
