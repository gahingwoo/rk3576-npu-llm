# kiln-chat — interactive LLM on the NPU

`kiln-chat` is a terminal chat over `librkllmrt`. Type a message and the model
replies, streaming tokens as they decode; each turn prints a `[bench]` line
(time-to-first-token and decode tok/s). Everything else is a **slash command** —
a line starting with `/`.

Config comes from `/etc/kiln/config.ini` (`[llm]` section); the commands below
change the running session, and some mirror config fields so you can try a value
before writing it to the file.

## Commands

| command | what it does |
|---|---|
| `/help` | list the commands |
| `/clear` | forget the conversation; keep the system prompt |
| `/new` | start a fresh session (clear + reset counters) |
| `/history [on\|off]` | multi-turn memory on/off; no argument shows the current state |
| `/system [text]` | show the system prompt, or set it (resets the session) |
| `/context` | show the context window and session counters |
| `/compact` | summarize the conversation to free up context |
| `/model [name]` | list `.rkllm` models, or switch to one |
| `/exit`, `/quit` | leave |

## How each is backed

Slash commands are a dispatch layer around the same generation call — they do
not change the inference path. What the closed runtime actually supports:

- **`/clear`, `/new`, `/history`, `/system`** are backed directly by the
  runtime. History is the runtime's own KV cache: `/clear` and `/new` call
  `rkllm_clear_kv_cache` (keeping or dropping the system prompt), `/history`
  toggles whether each turn is appended to it, and `/system` re-applies the chat
  template and clears the KV so the new system prompt takes effect cleanly.
- **`/model`** reloads the runtime (`rkllm_destroy` + `rkllm_init`), so a switch
  takes a few seconds. With no argument it lists `.rkllm` files next to the
  current model and marks the active one.
- **`/context`** is **partial by necessity**: the runtime exposes neither live
  KV usage nor a tokenizer, so it reports the context window size and what can be
  counted exactly (turns and tokens the model generated). Prompt-side token usage
  is not observable from the API.
- **`/compact`** is an **application-level approximation**: the runtime has no KV
  compaction, so `/compact` asks the model to summarize the conversation (one
  extra inference), then replaces the earlier turns with that summary folded into
  the system prompt. It frees context at the cost of one generation and whatever
  the summary leaves out.

A `/rewind`-style undo is intentionally absent: the runtime has no KV
snapshot/restore that would make it reliable, and faking it would change the
inference path.

## Persisting changes

`/model`, `/system` and `/history` affect the current run only. To keep a choice
across restarts, set the matching field in `/etc/kiln/config.ini`
(`model`, `system_prompt`, `keep_history`) — see [`CONFIG.md`](CONFIG.md).
