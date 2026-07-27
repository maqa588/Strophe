# Strophe 远程 ASR 接口规范

本文档定义 Strophe 客户端与远程语音识别服务之间的协议。服务端可以继续使用现有
Qwen3-ASR 1.7B 实现，同时新增 NVIDIA Parakeet-JA 路由。客户端上传的音频已经是
16 kHz、单声道、PCM WAV，服务端无需再次从视频中提取音频。

## 1. 模型路由

`model` 只允许以下稳定值：

| `model` | 服务端模型 | 适用语言 | 时间戳来源 |
|---|---|---|---|
| `qwen3-asr-1.7b` | 现有 Qwen3-ASR 1.7B | 中文、英文及多语言 | 现有 Qwen 对齐流程 |
| `parakeet-tdt-ctc-0.6b-ja` | `nvidia/parakeet-tdt_ctc-0.6b-ja` | 仅日语 | NeMo TDT 原生时间戳 |

不要让客户端提交任意 Hugging Face 仓库名称。服务端使用上表白名单将稳定路由映射到
实际模型，避免形成任意模型加载接口。

## 2. 健康检查

### `GET /health`

只检查 HTTP 服务本身：

```json
{"status":"ok"}
```

### `GET /ready?model=parakeet-tdt-ctc-0.6b-ja`

检查指定模型能否接受请求。模型可用时返回 HTTP 200：

```json
{
  "status": "ready",
  "model": "parakeet-tdt-ctc-0.6b-ja"
}
```

模型仍在加载或 GPU 不可用时返回 HTTP 503。未知模型返回 HTTP 422。
客户端会校验 `status == "ready"` 且响应中的 `model` 与请求完全一致；缺少或回显错误会
被视为协议未升级，避免选择 Parakeet 时服务器仍静默执行 Qwen。

## 3. 转写请求

### `POST /transcribe`

客户端会同时在 query 和 multipart 中发送路由参数：

```text
/transcribe
  ?stream=true
  &language=ja
  &lang=ja
  &model=parakeet-tdt-ctc-0.6b-ja
```

Multipart 字段：

| 字段 | 类型 | 必需 | 说明 |
|---|---|---:|---|
| `file` | WAV 文件 | 是 | 16 kHz、单声道、PCM |
| `model` | String | 是 | 上述稳定模型路由 |
| `language` | String | 是 | `auto`、`zh`、`zh-TW`、`en`、`ja` 等 |
| `lang` | String | 是 | 与 `language` 相同，为现有服务兼容字段 |

Query 与 multipart 中的 `model` 或语言字段不一致时应返回 HTTP 400，不能静默选择其中
一个。Parakeet 路由只接受 `ja` 或 `auto`；`auto` 必须规范化为 `ja`。

测试请求：

```bash
curl -N \
  'http://SERVER:8000/transcribe?stream=true&language=ja&lang=ja&model=parakeet-tdt-ctc-0.6b-ja' \
  -F 'language=ja' \
  -F 'lang=ja' \
  -F 'model=parakeet-tdt-ctc-0.6b-ja' \
  -F 'file=@sample-16k-mono.wav;type=audio/wav'
```

## 4. 流式响应

`stream=true` 时必须返回 NDJSON：

```http
Content-Type: application/x-ndjson; charset=utf-8
```

每个 JSON 对象独占一行，不使用 SSE 的 `data:` 前缀。

进度事件：

```json
{"type":"progress","progress":0.25,"message":"Transcribing with Parakeet-JA"}
```

`progress` 使用 `0.0...1.0`。最终结果事件：

```json
{"type":"result","data":{"status":"success","model":"parakeet-tdt-ctc-0.6b-ja","language":"ja","timestamps_sentence":[{"start":0.12,"end":2.84,"text":"今日は東京へ行きます。"}],"timestamps_word":[{"start":0.12,"end":0.48,"text":"今日"},{"start":0.48,"end":0.62,"text":"は"}]}}
```

约束：

- 所有时间都以整个上传文件起点为零，单位为秒。
- `start`、`end` 必须是有限数字，且 `0 <= start < end`。
- `timestamps_sentence` 是 Strophe 的首选输入，服务端必须提供。
- `timestamps_word` 可选，主要用于诊断或未来的客户端二次分段。
- `model` 必须回显实际执行的稳定路由，客户端会与请求值严格比较。
- 句子按开始时间升序排列，不得重叠或包含空文本。
- 最终结果必须压缩为单行 JSON。

错误事件：

```json
{"type":"error","message":"CUDA out of memory"}
```

在写出任何流式内容前发现的参数错误应直接使用对应的 HTTP 4xx/5xx；开始流式响应后才
发生的错误使用上述 `error` 事件。

## 5. FastAPI 路由参考

下面是接口层参考。`QwenAdapter` 连接服务器现有的 Qwen3-ASR 1.7B 推理代码；
`ParakeetAdapter` 的实现见下一节。

```python
import asyncio
import json
import os
import tempfile
from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse

MODEL_QWEN = "qwen3-asr-1.7b"
MODEL_PARAKEET = "parakeet-tdt-ctc-0.6b-ja"
ALLOWED_MODELS = {MODEL_QWEN, MODEL_PARAKEET}

app = FastAPI()
gpu_lock = asyncio.Lock()
model_registry = {
    MODEL_QWEN: QwenAdapter(),          # 接入现有 1.7B 实现
    MODEL_PARAKEET: ParakeetAdapter(),  # 可采用懒加载
}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/ready")
async def ready(model: str = Query(...)):
    if model not in ALLOWED_MODELS:
        raise HTTPException(422, "unknown model")
    adapter = model_registry[model]
    if not adapter.is_ready:
        async with gpu_lock:
            await asyncio.to_thread(adapter.load)
    if not adapter.is_ready:
        raise HTTPException(503, "model is not ready")
    return {"status": "ready", "model": model}


@app.post("/transcribe")
async def transcribe(
    file: Annotated[UploadFile, File(...)],
    form_model: Annotated[str, Form(alias="model")],
    language: Annotated[str, Form(...)],
    lang: Annotated[str, Form(...)],
    query_model: Annotated[str, Query(alias="model")],
    query_language: Annotated[str, Query(alias="language")],
    query_lang: Annotated[str, Query(alias="lang")],
    stream: bool = Query(True),
):
    if form_model != query_model:
        raise HTTPException(400, "query/form model mismatch")
    if language != lang or language != query_language or language != query_lang:
        raise HTTPException(400, "query/form language mismatch")
    if form_model not in ALLOWED_MODELS:
        raise HTTPException(422, "unknown model")
    if form_model == MODEL_PARAKEET and language not in {"ja", "auto"}:
        raise HTTPException(422, "Parakeet-JA only accepts ja or auto")

    normalized_language = "ja" if form_model == MODEL_PARAKEET else language
    suffix = os.path.splitext(file.filename or "input.wav")[1] or ".wav"
    fd, audio_path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    with open(audio_path, "wb") as output:
        while chunk := await file.read(1024 * 1024):
            output.write(chunk)

    async def events():
        try:
            yield json.dumps({
                "type": "progress",
                "progress": 0.05,
                "message": f"Loading {form_model}",
            }, ensure_ascii=False) + "\n"

            # V100 16GB 建议串行化 GPU 推理；若两个模型无法同时驻留，
            # adapter 可在锁内执行 LRU 卸载/加载。
            async with gpu_lock:
                result = await asyncio.to_thread(
                    model_registry[form_model].transcribe,
                    audio_path,
                    normalized_language,
                )

            yield json.dumps({
                "type": "result",
                "data": {
                    "status": "success",
                    "model": form_model,
                    "language": normalized_language,
                    "timestamps_sentence": result.sentences,
                    "timestamps_word": result.words,
                },
            }, ensure_ascii=False, separators=(",", ":")) + "\n"
        except Exception as error:
            yield json.dumps({
                "type": "error",
                "message": str(error),
            }, ensure_ascii=False, separators=(",", ":")) + "\n"
        finally:
            os.unlink(audio_path)

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
    )
```

## 6. Parakeet-JA NeMo 适配器

模型应在进程内复用，不要每个请求重新下载或实例化：

```python
from dataclasses import dataclass

import torch
import nemo.collections.asr as nemo_asr
from omegaconf import open_dict


@dataclass
class ASRResult:
    sentences: list[dict]
    words: list[dict]


class ParakeetAdapter:
    MODEL_ID = "nvidia/parakeet-tdt_ctc-0.6b-ja"

    def __init__(self):
        self.model = None

    @property
    def is_ready(self) -> bool:
        # 若采用懒加载，可在 /ready 中触发 load() 后返回状态。
        return self.model is not None

    def load(self):
        if self.model is not None:
            return
        model = nemo_asr.models.ASRModel.from_pretrained(
            model_name=self.MODEL_ID
        )
        model = model.to("cuda").eval()

        # NeMo 官方时间戳流程：保留 alignment 并计算 timestamp。
        decoding = model.cfg.decoding
        with open_dict(decoding):
            decoding.preserve_alignments = True
            decoding.compute_timestamps = True
        model.change_decoding_strategy(decoding)
        self.model = model

    @torch.inference_mode()
    def transcribe(self, audio_path: str, language: str) -> ASRResult:
        self.load()
        with torch.autocast(device_type="cuda", dtype=torch.float16):
            hypotheses = self.model.transcribe(
                [audio_path],
                batch_size=1,
                return_hypotheses=True,
            )

        # RNNT/TDT 某些 NeMo 版本返回 (best_hypotheses, all_hypotheses)。
        if isinstance(hypotheses, tuple):
            hypotheses = hypotheses[0]
        hypothesis = hypotheses[0]
        timestamp_data = hypothesis.timestep

        # FastConformer 8 倍下采样；本模型通常为 8 * 10ms = 80ms。
        stride = 8 * float(self.model.cfg.preprocessor.window_stride)
        words = []
        for item in timestamp_data.get("word", []):
            text = item.get("word", item.get("char", "")).strip()
            if not text:
                continue
            start = float(item["start_offset"]) * stride
            end = float(item["end_offset"]) * stride
            if end > start:
                words.append({"start": start, "end": end, "text": text})

        sentences = sentenceize_japanese(words)
        return ASRResult(sentences=sentences, words=words)


def sentenceize_japanese(
    words: list[dict],
    max_chars: int = 17,
    max_duration: float = 6.2,
    split_gap: float = 0.8,
) -> list[dict]:
    sentences: list[dict] = []
    current: list[dict] = []

    def flush():
        if not current:
            return
        text = "".join(item["text"] for item in current).strip()
        if text:
            sentences.append({
                "start": current[0]["start"],
                "end": current[-1]["end"],
                "text": text,
            })
        current.clear()

    for word in words:
        if current and word["start"] - current[-1]["end"] >= split_gap:
            flush()
        current.append(word)
        text = "".join(item["text"] for item in current)
        duration = current[-1]["end"] - current[0]["start"]
        if (
            text.endswith(("。", "！", "？", "!", "?"))
            or len(text) >= max_chars
            or duration >= max_duration
        ):
            flush()

    flush()
    return sentences
```

不同 NeMo 版本可能把时间戳放在 `hypothesis.timestamp`，或直接提供秒单位的
`start`/`end`。适配器应在部署时打印一次 `hypothesis` 和时间戳键并做兼容归一化，但
对 Strophe 输出必须始终遵守第 4 节格式。

日语句子聚合至少应满足：

- 遇到 `。！？!?` 结束当前字幕句。
- 无标点时以停顿、最大字符数和最大时长切分。
- 建议目标时长不超过 6.2 秒。
- 不要在日语 token 之间自动插入空格。
- 聚合句的 `start` 取首 token 开始，`end` 取末 token 结束。

## 7. V100 部署建议

- 使用与服务器 CUDA 驱动匹配的 PyTorch，再安装 `nemo_toolkit[asr]`。
- Parakeet 使用 FP16；V100 不支持 BF16，应避免选择 BF16 autocast。
- 16GB 显存建议一次只执行一个 GPU 推理任务。
- 如果 Qwen3-ASR 1.7B 与 Parakeet 无法同时驻留，使用单模型 LRU：切换路由时先释放
  当前模型、执行 `torch.cuda.empty_cache()`，再加载目标模型。
- 模型在启动或首次 `/ready` 时下载到持久化 Hugging Face 缓存目录。
- 对上传大小、音频时长和并发队列设置明确上限。

在已经安装匹配 CUDA 的 PyTorch 后，服务层的基本依赖可以按需加入：

```bash
pip install 'nemo_toolkit[asr]' fastapi uvicorn python-multipart soundfile
```

Parakeet-JA 模型采用 CC BY 4.0，服务端分发或对外提供相关功能时应保留 NVIDIA 和模型
页面的署名及许可信息。
