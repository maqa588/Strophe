# Strophe 云端 ForcedAligner 接口

Karaoke 批量识别已有文字和 cue 时间，因此不得调用 `/transcribe`。客户端使用：

```text
POST /align
multipart/form-data
  file:     完整 16 kHz mono PCM WAV
  language: auto | zh | en | ja | ko ...
  cues:     JSON 数组
```

`cues`：

```json
[
  {
    "id": "A4AE9A8B-7A14-4C25-8D4B-24F2C14C6513",
    "text": "如果不是你我不会确定",
    "startTime": 80.83,
    "endTime": 85.56
  }
]
```

响应时间必须是媒体的绝对秒数：

```json
{
  "status": "success",
  "model": "qwen3-forced-aligner-0.6b",
  "cues": [
    {
      "id": "A4AE9A8B-7A14-4C25-8D4B-24F2C14C6513",
      "words": [
        {"text": "如", "start": 80.91, "end": 81.13, "confidence": null},
        {"text": "果", "start": 81.13, "end": 81.39, "confidence": null}
      ]
    }
  ]
}
```

## FastAPI 实现

安装官方运行库：

```bash
pip install -U qwen-asr fastapi uvicorn python-multipart soundfile
```

在现有 `strophe_server` 中增加以下模块。模型应作为进程级单例加载，不要在每个 cue 或每个请求中重新加载：

```python
import asyncio
import json
import os
import tempfile

import numpy as np
import soundfile as sf
import torch
from fastapi import File, Form, HTTPException, UploadFile
from qwen_asr import Qwen3ForcedAligner

ALIGNER_ID = "Qwen/Qwen3-ForcedAligner-0.6B"

LANGUAGE_NAMES = {
    "zh": "Chinese",
    "zh-TW": "Chinese",
    "yue": "Cantonese",
    "en": "English",
    "de": "German",
    "es": "Spanish",
    "fr": "French",
    "it": "Italian",
    "pt": "Portuguese",
    "ru": "Russian",
    "ko": "Korean",
    "ja": "Japanese",
}

aligner = None
aligner_lock = asyncio.Lock()


def get_aligner():
    global aligner
    if aligner is None:
        aligner = Qwen3ForcedAligner.from_pretrained(
            ALIGNER_ID,
            dtype=torch.bfloat16,
            device_map="cuda:0",
        )
    return aligner


def align_cues(audio_path: str, cues: list[dict], language: str):
    samples, sample_rate = sf.read(audio_path, dtype="float32", always_2d=False)
    if samples.ndim == 2:
        samples = samples.mean(axis=1)

    language_name = LANGUAGE_NAMES.get(language)
    if language == "auto":
        # ForcedAligner 自身不做可靠的语言识别。可从项目语言传入；
        # 若 UI 仍为 auto，可按服务器业务默认值处理。
        language_name = "Chinese"
    if language_name is None:
        raise ValueError(f"unsupported alignment language: {language}")

    model = get_aligner()
    output = []
    for cue in cues:
        start = float(cue["startTime"])
        end = float(cue["endTime"])
        text = str(cue["text"]).strip()
        if not text or not (0 <= start < end):
            continue

        lower = max(0, round(start * sample_rate))
        upper = min(len(samples), round(end * sample_rate))
        clip = np.ascontiguousarray(samples[lower:upper])
        if clip.size == 0:
            continue

        # qwen-asr 支持 (numpy array, sample rate) 音频输入。
        aligned = model.align(
            audio=(clip, sample_rate),
            text=text,
            language=language_name,
        )[0]

        words = [
            {
                "text": item.text,
                # 官方结果是 cue 内相对秒数；转换成媒体绝对秒数。
                "start": start + float(item.start_time),
                "end": start + float(item.end_time),
                "confidence": None,
            }
            for item in aligned
        ]
        output.append({"id": cue["id"], "words": words})
    return output


@app.post("/align")
async def align_only(
    file: UploadFile = File(...),
    language: str = Form(...),
    cues: str = Form(...),
):
    try:
        cue_list = json.loads(cues)
    except (TypeError, json.JSONDecodeError) as error:
        raise HTTPException(422, f"invalid cues JSON: {error}") from error
    if not isinstance(cue_list, list):
        raise HTTPException(422, "cues must be a JSON array")

    suffix = os.path.splitext(file.filename or "input.wav")[1] or ".wav"
    fd, audio_path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    try:
        with open(audio_path, "wb") as output:
            while chunk := await file.read(1024 * 1024):
                output.write(chunk)

        # 与 ASR 共用同一 GPU 时，应复用服务器已有的 gpu_lock。
        async with aligner_lock:
            result = await asyncio.to_thread(
                align_cues,
                audio_path,
                cue_list,
                language,
            )
        return {
            "status": "success",
            "model": "qwen3-forced-aligner-0.6b",
            "cues": result,
        }
    finally:
        os.unlink(audio_path)
```

客户端不会向 `/align` 发送 ASR model，也不需要 `timestamps_sentence`、SRT 或识别文本。服务端日志中，批量 Karaoke 的正确请求应显示为：

```text
POST /align HTTP/1.1
```

而不是：

```text
POST /transcribe?...model=qwen3-asr-1.7b...
```
