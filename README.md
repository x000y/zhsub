# zhsub — 悬浮双语实时字幕 (macOS)

> 🤖 **DeepSeek Harness v4 Flash 作品** by 易

把任意视频/直播的声音实时转成 **中英双语悬浮字幕**，全本地运行（无需云服务、免费）。

## ✨ 功能

- 🎙️ **流式语音识别** (sherpa-onnx zipformer)：内置英文模型，可下载**多语言8语模型**（英/日/中/俄/泰/越/印尼/阿拉伯，自动检测语言）
- 🌐 **本地 AI 翻译** (Hy-MT2, mlx)：英文 → 中文，支持 **8bit / 4bit** 两种量化（4bit 体积减半），LRU 缓存加速
- 🖥️ **系统级音频捕获** (audiotee)：`--pid 0` 捕获整个 Mac 的声音，任意 App 播放都有字幕
- ⚙️ **设置面板**：模型下载/切换、四渠道（hf-mirror / HF 官方 / **阿里 ModelScope 免代理** / 自定义）、代理、缓存上限、字幕更新节奏
- 🔧 **引擎看护**：识别进程崩溃自动重启
- 🔄 **自适应节流**：根据翻译耗时动态调整字幕节奏，中文字幕跟嘴不跳动
- 🔔 **检查更新**：设置面板一键检查 GitHub 新版本
- 📦 **模型管理器** (`zhsub-dl.py`)：断点续传、大小校验、NDJSON 进度事件

## 📥 安装

### 方式一：直接下载 App（推荐）

从 [GitHub Releases](https://github.com/x000y/zhsub/releases) 下载：

| 包 | 大小 | 说明 |
|---|---|---|
| `zhsub-0.1.2-drag.dmg` | 335MB | **完整版**：内置英文模型，开箱即用 |
| `zhsub-0.1.2-lite.dmg` | 97MB | **瘦身版**：首次打开在设置面板下载模型 |

安装：双击 dmg → 把 `zhsub.app` 拖到 Applications → 运行。
> 未签名 app 首次打开若提示"无法验证开发者"，右键 → 打开 → 确认即可。

### 方式二：源码运行

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
~/zh-sub-engine/.venv/bin/python zhsub-dl.py download --model Hy-MT2-1.8B-4bit

# 4. 启动悬浮字幕
./subtitles.sh
```

> 需要 audiotee: 参考 [livecaption](https://github.com/laurent22/livecaption) 编译 `bin/audiotee` 放入 `~/livecaption/bin/`。

## 🔐 系统音频权限（必须！不出字幕先看这里）

zhsub 通过 **audiotee** 捕获系统音频（麦克风权限不够，需要「**屏幕与系统音频录制**」权限）。

**首次使用请授权**：
1. 打开 **系统设置 → 隐私与安全性 → 屏幕与系统音频录制**
2. 勾选 **「悬浮双语字幕」**（没有就点 **+** 添加 `/Applications/zhsub.app`）
3. 完全退出 App 再重新打开

**App 内也能跳转**：设置面板（⚙）→ 「系统音频权限: 若不出字幕请检查」→ 点 **「前往授权 →」** 直接打开设置页。

> 授权后若仍不出字幕，检查是否有其他占用系统音频的程序（如旧版 livecaption 进程）：
> `ps aux | grep livecaption` 有残留就 `kill` 掉。

## 🎮 使用

- **拖动**字幕窗口 = 移动
- **滚轮** = 缩放字号
- **Option + 滚轮** = 调整字幕缓冲延迟
- **左上角齿轮** = 设置面板（模型管理 / 下载渠道 / 代理 / 检查更新 / 退出）

## 🚀 发版（版本号自动同步）

```bash
bash release.sh 0.1.3        # 一键发版: 改版本→提交→tag→push→打包→签名→dmg→GitHub Release
bash release.sh 0.1.3 --lite # 只发瘦身版
bash release.sh --dry-run 0.1.3  # 只打包不发布(预览)
```

- 版本号会**自动同步**更新到：`floater.swift`（App 内显示）、`pack.sh`（默认版本）、git tag、Release 标题、dmg 文件名
- App 内「检查更新」会对比 GitHub 最新 tag，发现新版本提示下载

## 📁 文件说明

| 文件 | 作用 |
|---|---|
| `floater.swift` | 悬浮字幕窗口 + 设置面板 (AppKit, `swiftc -O floater.swift -o floater`) |
| `zhsub.py` | 流式 ASR + 翻译引擎 (NDJSON 事件流, 自适应节流) |
| `zhsub-dl.py` | 模型下载器 / 配置管理（多渠道 + 断点续传） |
| `zhsub-mt.py` | 独立翻译辅助 (Hy-MT2) |
| `subtitles.sh` | 一键启动脚本 |
| `pack.sh` | 打包脚本 (`--full` 内置模型, 版本号自动读 git tag) |
| `release.sh` | 一键发版脚本 (版本号同步: 提交/tag/打包/签名/dmg/GitHub Release) |
| `assets/` | 图标 (zhsub.icns) / GitHub mark |

## ⚙️ 配置

`~/Library/Application Support/zhsub/config.json`:

```json
{"asr": "multi-8lang", "mt": "Hy-MT2-1.8B-4bit",
 "channel": "hf-mirror", "custom_url": "", "proxy": "http://127.0.0.1:1088",
 "cache_size": 1024, "sub_gap": 1200}
```

## 🧠 模型

| 模型 | 大小 | 语言 | 渠道 |
|---|---|---|---|
| en-0626 | 253MB | 英文 | 内置/下载 |
| multi-zh-hans | 69MB | 中文 | ModelScope 免代理 |
| multi-8lang | 324MB | 英/日/中/俄/泰/越/印尼/阿 | HF (需代理) |
| multilingual-2025 | ~500MB | 全语版(含韩语) | HF gated |
| Hy-MT2-1.8B-8bit | 1.8GB | 翻译 | ModelScope 免代理 |
| Hy-MT2-1.8B-4bit | 961MB | 翻译 | ModelScope 免代理 |

## License

AGPL-3.0
