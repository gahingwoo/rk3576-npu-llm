# Open WebUI、LangChain 与任意 OpenAI 客户端

英文版:[OPENWEBUI.md](../OPENWEBUI.md)。

`kiln-serve` 是 **OpenAI 兼容**的 HTTP API,所以整个 OpenAI 生态**零改代码**就能指向你的板子——
只是换个 base URL。配上 [**Open WebUI**](https://github.com/open-webui/open-webui),你就得到一个
**完全由板子 NPU 驱动的 ChatGPT 式网页**——私有、离线、无需 API key。

base URL 永远是 **`http://<板子IP>:8080/v1`**(默认端口,在 `[server]` 里设)。API key 被忽略,
随便填个非空字符串即可。

## 1. 在板子上启动服务

```sh
sudo kiln-config        # Server → host = 0.0.0.0(所有网卡),然后 service → enable
# 或一次性:
kiln-serve --host 0.0.0.0 --port 8080
```

`host = 0.0.0.0` 很关键——`127.0.0.1` 只接受板子自己的连接。从局域网另一台机器验证:

```sh
curl http://<板子IP>:8080/v1/models
```

## 2. Open WebUI(ChatGPT 式网页)

用 Docker 跑 Open WebUI——**在局域网任意一台机器上**(PC,或板子本身如果性能够),指向板子:

```sh
docker run -d -p 3000:8080 \
  -e OPENAI_API_BASE_URL=http://<板子IP>:8080/v1 \
  -e OPENAI_API_KEY=kiln \
  -e ENABLE_OLLAMA_API=false \
  -v open-webui:/app/backend/data \
  --name open-webui ghcr.io/open-webui/open-webui:main
```

打开 **http://localhost:3000**,注册第一个(本地)账号,板子的模型就出现在模型选择里(名字来自
`GET /v1/models`——即 `.rkllm` 文件名)。对话会逐 token 从 NPU 流式输出。

> 已经在跑 Open WebUI?到 **设置 → 管理 → 连接 → OpenAI API** 加一条:URL 填
> `http://<板子IP>:8080/v1`,key 填 `kiln`。

## 3. `openai` Python SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://<板子IP>:8080/v1", api_key="kiln")

stream = client.chat.completions.create(
    model="kiln",                                   # 随便一个 id;板子只有一个模型
    messages=[{"role": "user", "content": "用一句话打个招呼。"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## 4. LangChain

```python
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(base_url="http://<板子IP>:8080/v1", api_key="kiln", model="kiln")
print(llm.invoke("讲一个关于 Rockchip 的冷知识。").content)
```

任何说 OpenAI chat completions 的工具都一样:LlamaIndex、Vercel AI SDK、Continue.dev 等——设好
base URL、key 随便填。

## 5. 纯 `curl`

```sh
# 列模型
curl http://<板子IP>:8080/v1/models

# 流式对话(SSE)
curl -N http://<板子IP>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"你好"}],"stream":true}'
```

## 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET`  | `/health` | 存活探测 |
| `GET`  | `/v1/models` | 已加载的 `.rkllm` 模型 |
| `POST` | `/v1/chat/completions` | OpenAI 对话;`"stream": true` → SSE 流 |
| `POST` | `/v1/vision/classify` | **非** OpenAI 标准:POST 一张图(裸 body 或 multipart `file=`),返回 top-N 类别 |
| `POST` | `/v1/vision/detect` | POST 一张图,返回 YOLO 框(`?conf=` / `?iou=` 调阈值) |

```sh
curl http://<板子IP>:8080/v1/vision/classify --data-binary @cat.jpg
curl "http://<板子IP>:8080/v1/vision/detect?conf=0.25" --data-binary @street.jpg
```

## 注意与安全

- **API 无鉴权、CORS 全开(`*`)**——它面向**可信局域网**。别直接暴露到公网;要远程访问就放在
  反向代理(nginx/Caddy)后面加 TLS + 鉴权。
- NPU 是**单租户**:请求被串行化,并发调用会排队而非并行。
- 请求里的 `model` 被忽略(板子只服务它加载的那一个)——随便填 id;真实名字用 `GET /v1/models`。
- 仅视觉的板子(如 RK3568,无 `.rkllm`)在 `/v1/chat/completions` 上返回 `503`,视觉端点照常。

服务的配置字段和 systemd 单元见 [SERVER.md](../SERVER.md)。
