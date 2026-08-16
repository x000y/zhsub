# zhsub — 悬浮双语实时字幕 (macOS)

把任意视频/直播的声音实时转成 **中英双语悬浮字幕**，全本地运行（无需云服务、免费）。

## 功能

- 🎙️ **流式语音识别** (sherpa-onnx zipformer)：内置英文模型，可下载**多语言8语模型**（英/日/中/俄/泰/越/印尼/阿拉伯，自动检测语言）
- 🌐 **本地 AI 翻译** (Hy-MT2 1.8B, mlx)：英文 → 中文（也支持繁中/日/韩目标语言），LRU 缓存加速
- 🖥️ **系统级音频捕获** (audiotee)：`--pid 0` 捕获整个 Mac 的声音，任意 App 播放都有字幕
- ⚙️ **设置面板**：模型下载/切换、下载渠道、代理、进度条、引擎热重启
- 🔧 **引擎看护**：识别进程崩溃自动重启
- 📦 **模型管理器** (`zhsub-dl.py`)：多下载渠道（hf-mirror / HF 官方 / **阿里 ModelScope 免代理** / 自定义）、断点续传、大小校验

## 快速开始

```bash
# 1. 准备 Python 环境 (需要 Python 3.12)
python3 -m venv ~/zh-sub-engine/.venv
~/zh-sub-engine/.venv/bin/pip install sherpa-onnx mlx-lm transformers huggingface_hub httpx soundfile numpy

# 2. 下载 ASR 模型 (英文内置放 models/, 多语言8语可下载)
~/zh-sub-engine/.venv/bin/python zhsub-dl.py status
~/zh-sub-engine/.venv/bin/python zhsub-dl.py set --asr multi-8lang --channel hf-mirror --proxy http://127.0.0.1:1088
~/zh-sub-engine/.venv/bin/python zhsub-dl.py download --model multi-8lang

# 3. 下载翻译模型 (ModelScope 免代理, 国内直连)
~/zh-sub-engine/.venv/bin/python zhsub-dl.py set --channel modelscope
~/zh-sub-engine/.venv/bin/python zhsub-dl.py download --model Hy-MT2-1.8B-8bit

# 4. 启动悬浮字幕
./subtitles.sh
```

> 需要 audiotee: 参考 [livecaption](https://github.com/laurent22/livecaption) 编译 `bin/audiotee` 放入 `~/livecaption/bin/`。

## 使用

- **拖动**字幕窗口 = 移动
- **滚轮** = 缩放字号
- **Option + 滚轮** = 调整字幕缓冲延迟
- **左上角齿轮** = 设置面板（模型管理 / 下载渠道 / 代理 / 重启引擎）

## 文件说明

| 文件 | 作用 |
|---|---|
| `floater.swift` | 悬浮字幕窗口 + 设置面板 (AppKit, `swiftc -O floater.swift -o floater`) |
| `zhsub.py` | 流式 ASR + 翻译引擎 (NDJSON 事件流) |
| `zhsub-dl.py` | 模型下载器 / 配置管理（多渠道 + 断点续传） |
| `zhsub-mt.py` | 独立翻译辅助 (Hy-MT2) |
| `subtitles.sh` | 一键启动脚本 |

## 配置

`~/Library/Application Support/zhsub/config.json`:

```json
{"asr": "multi-8lang", "mt": "Hy-MT2-1.8B-8bit",
 "channel": "hf-mirror", "custom_url": "", "proxy": "http://127.0.0.1:1088"}
```

## 模型

| 模型 | 大小 | 语言 | 渠道 |
|---|---|---|---|
| en-0626 | 253MB | 英文 | 内置 |
| multi-zh-hans | 69MB | 中文 | ModelScope 免代理 |
| multi-8lang | 324MB | 英/日/中/俄/泰/越/印尼/阿 | HF (需代理) |
| multilingual-2025 | ~500MB | 全语版(含韩语) | HF gated |
| Hy-MT2-1.8B-8bit | 1.8GB | 翻译 | ModelScope 免代理 |

## License

AGPL-3.0
