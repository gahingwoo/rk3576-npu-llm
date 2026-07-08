# kiln-serve — OpenAI-compatible LLM API on the NPU

`kiln-serve` puts the LLM running on the RK3576 NPU behind an HTTP API that
speaks the OpenAI `/v1/chat/completions` protocol, so existing OpenAI clients
(the `openai` Python/JS SDKs, LangChain, `curl`, most chat frontends) point at
the board and work unmodified. It wraps the same `librkllmrt` call sequence as
`kiln-chat` (via `kiln_llm.h`) — no re-implemented inference — and reads the
shared `/etc/kiln/config.ini`.

It is a single-model, single-tenant server: the model is loaded once at startup
(`rkllm_init` maps the whole model) and requests are serialized (the NPU runs
one generation at a time). Header-only deps only — `cpp-httplib` + `nlohmann/json`,
no Python, no extra runtime.

## Run

```sh
kiln-serve                      # reads [server] host/port/model from the config
kiln-serve --host 0.0.0.0 --port 8080 --model /opt/models/other.rkllm   # overrides
```

Or as a service (installed disabled by `kiln-install.sh`):

```sh
sudo systemctl enable --now kiln-serve      # start now + on boot
sudo systemctl status kiln-serve
```

## Endpoints

| method | path | notes |
|---|---|---|
| `GET`  | `/health` | `{"status":"ok"}` |
| `GET`  | `/v1/models` | lists the `.rkllm` files next to the loaded model |
| `POST` | `/v1/chat/completions` | OpenAI chat; `"stream": true` → SSE token stream |
| `POST` | `/v1/vision/classify` | optional — image → top-N classes (only if a `.rknn` is configured; else `503`) |

The server is **stateless** per request: it flattens the OpenAI `messages` array
into one ChatML prompt each call (the client resends history, per the OpenAI
contract), so multi-turn works without server-side session state.

## curl

Streaming:

```sh
curl -N http://<board>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","stream":true,
       "messages":[{"role":"user","content":"Explain the RK3576 NPU in one line."}]}'
```

Non-streaming:

```sh
curl http://<board>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
```

Vision (custom, not an OpenAI shape) — POST the raw image bytes:

```sh
curl http://<board>:8080/v1/vision/classify?top_n=5 \
  --data-binary @cat.jpg
# -> {"model":"...rknn","inference_ms":6.1,"top":[{"index":281,"label":"tabby","score":0.62}, ...]}
```

## OpenAI SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://<board>:8080/v1", api_key="not-needed")
for chunk in client.chat.completions.create(
        model="qwen",
        messages=[{"role": "user", "content": "hello"}],
        stream=True):
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## Configuration

All defaults come from `[server]` and `[llm]` in `/etc/kiln/config.ini` — edit
it by hand (see [`CONFIG.md`](CONFIG.md)). `[server].llm_model` (blank = use
`[llm].model`) picks which `.rkllm` the server loads; the sampling / context /
system-prompt come from `[llm]`.

## Limits (honest)

- One model per process (loaded at startup). To serve a different `.rkllm`,
  restart with `--model` or change the config. The `model` field in a request is
  echoed back but does not hot-swap.
- One generation at a time (NPU is single-tenant); concurrent requests queue.
- HTTP only (no TLS). Put it behind a reverse proxy if you need HTTPS/auth.
