# Local Control — 离线手势鼠标与语音定位

在 Apple Silicon Mac 上，用食指移动鼠标，用手势点击，用语音说出附近可见文字来定位目标。摄像头识别、语音转写、屏幕文字识别和 Bonsai 推理都在本机完成。

**语音只负责定位，不执行点击。** 例如，把指针移到标签附近，说“Codex”，指针会移动到识别出的目标并暂时锁定；再用拇指与中指捏合完成左键点击。

English: An offline desktop controller. Point with your index finger, name a nearby visible label to target it, and pinch to click. Argmax transcribes audio; Bonsai selects a local OCR candidate. Voice never clicks.

## 启动 / Launch

这台 Mac 已准备好模型和运行时。在 Finder 中双击项目里的 **[Local Control.app](<.build/Local Control.app>)**。`.build` 是隐藏文件夹，可在项目窗口按 `⌘⇧.` 显示，或在项目目录运行：

```bash
open ".build/Local Control.app"
```

命令行备用入口：

```bash
python3 desktop.py
```

也可以双击项目中的 **[Launch Local Control.command](<Launch Local Control.command>)**。启动器会在缺少原生辅助程序时编译，并在需要时启动已安装的本地 Bonsai 服务。它不会下载缺失的模型。

**English launch:** On this prepared Mac, open `.build/Local Control.app` in Finder, or run `python3 desktop.py` from the project folder. Grant Camera, Microphone, Accessibility, and Screen Recording permissions, then click **Enable pointer**. The app starts paused.

这个 `.app` 是已准备项目的 Finder 启动器。项目文件、Argmax 模型和用户目录中的 Bonsai/MLX 运行时仍需要保留；单独复制 `.app` 到另一台电脑不能运行。移动项目目录后，请重新执行 `bash scripts/build_product.sh`。

首次使用，请在 **系统设置 → 隐私与安全性** 中为系统提示的 Local Control 或启动它的终端授权：

- **摄像头 / Camera**：识别手部。
- **麦克风 / Microphone**：采集待转写的语音。
- **辅助功能 / Accessibility**：移动鼠标和发送点击。
- **屏幕录制 / Screen Recording**：读取指针附近的可见文字。

修改权限后可能需要完全退出并重新启动。默认状态为 **PAUSED**；在预览窗口点击 **Enable pointer**，或在该窗口按空格开启。

| 输入 | 行为 |
| --- | --- |
| 食指移动 | 移动主显示器上的指针 |
| 拇指 + 中指捏合 | 左键单击；松开后才能再次触发 |
| 拇指 + 无名指捏合 | 右键单击 |
| 说出附近文字，例如“Codex” | Argmax 转写 → 局部 OCR → Bonsai 选择 → 指针定位；不点击 |
| 明显移动手部 | 解除语音定位后的指针锁定 |
| 空格（控制窗口内） | 开启 / 暂停 |
| Escape | 暂停控制 |
| Q（控制窗口内）或关闭窗口 | 退出 |

其他启动方式：

```bash
python3 desktop.py --check
python3 desktop.py --gesture-only
python3 desktop.py --speech-model base --language auto
```

`--check` 检查已安装资产、原生程序和正在运行的模型服务；它不会自动启动 Bonsai。`--gesture-only` 仅运行摄像头和手势鼠标，不启用语音定位。

## 模型与离线准备 / Local models

需要 Apple Silicon、macOS 14+、Python 3.9+、Xcode Command Line Tools，以及 Argmax 的 `whisperkit-cli`。摄像头手部识别和 OCR 使用 macOS 自带的 Vision 框架，不依赖浏览器 CDN 或额外的 Python 视觉库。

在允许联网的准备阶段安装并缓存 Argmax：

```bash
brew install whisperkit-cli
bash scripts/setup_models.sh --model base --language auto
bash scripts/build_product.sh
```

桌面产品默认使用 **多语言 Whisper base**，支持中文和英文。`tiny.en` / `base.en` 是英语模型；`tiny` / `base` 是多语言模型。模型与 tokenizer 存放于项目的 `models/`，不提交到 Git。

Bonsai 使用这台 Mac 上已安装的 **Ternary Bonsai-2 2B**：

```text
~/.lmstudio/models/prism-ml/Ternary-Bonsai-2-2B-mlx-2bit
```

`scripts/start_bonsai.sh` 使用 LM Studio 已安装、支持该模型的 MLX 运行时，将服务绑定到 `127.0.0.1:1234`，模型标识为 `bonsai-local`。可手动启动：

```bash
bash scripts/start_bonsai.sh
```

另一台 Mac 需要预先安装兼容运行时和模型；可用 `BONSAI_MODEL_PATH`、`BONSAI_PYTHON` 指定本机路径。启动器不会从云端补齐它们。使用的 HTTP 接口是 **Bonsai 的本机接口**；Argmax 通过原生 Swift CLI 调用，**没有使用 Argmax Local Server API**。

**English setup:** Before going offline, install the requirements above, cache multilingual Whisper `base` with `scripts/setup_models.sh`, and install the Bonsai-2 2B weights plus a compatible local MLX runtime. Run `bash scripts/build_product.sh` to build the Finder launcher. Keep the project and local model/runtime folders in place; the launcher is not a standalone transferable bundle.

Argmax 推理进程禁止联网。Bonsai 启动脚本禁止外网，仅允许本机回环通信，并开启模型库的离线模式。`127.0.0.1` 在 Wi-Fi 关闭后仍可使用。

**2026-11-14 实测：** 这台 Mac 的 Wi-Fi 已实际关闭，摄像头和真实屏幕 OCR 检查通过；合成语音经真实 Argmax、Bonsai 和控制器生成了正确的 `Codex` 移动指令。检查结束后已恢复 Wi-Fi。该链路测试截获鼠标指令，未向系统发送移动或点击；真人说“Codex”后实际定位再捏合点击的完整连续演示仍需完成。具体证据和范围见 [验证记录](docs/VERIFICATION.md)，操作流程见 [演示指南](docs/DEMO.md)。

## 定位范围与当前限制

- 目标来自语音开始时指针附近约 **720 × 420** 屏幕点的 OCR 区域；先把手移到目标附近。
- Bonsai 只选择 OCR 已识别出的文字 ID，不生成鼠标坐标。
- 重复标签、找不到文字、歧义或过期结果不会定位。
- 支持的是当前可见文字，不是全屏图标识别、隐藏标签搜索或任意界面的自主操作。
- 原型针对主显示器；窗口遮挡、很小的文字、光线、手部姿态和噪声都可能影响识别。
- 已完成的断网组件检查不能替代实际语音定位后手势点击的连续操作验收。请按 [两分钟演示检查表](docs/DEMO.md) 验证。

## 独立的纯转写接口

原来的 `src/stt`、`cli.py`、`main.py` 仍然只返回文字，不识别手势、不执行操作：

```bash
python3 cli.py check
python3 cli.py transcribe assets/samples/select_this_item.wav --json
python3 cli.py stream
```

```python
from stt import STTConfig, WhisperKitEngine

engine = WhisperKitEngine(STTConfig(model_name="base", language="auto"))
print(engine.transcribe("recording.wav").text)
```

运行 API 示例时使用 `PYTHONPATH=src python3 your_script.py`。`WhisperKitStreamer` 提供 `on_text` 回调与 `get_text(timeout)`；原始语音不会在 STT 层被解释成动作。

## 测试与文档

```bash
python3 -m unittest discover tests -v
STT_INTEGRATION=1 python3 -m unittest discover tests -v
.build/LocalControl.app/Contents/MacOS/GestureCamera --self-test
python3 scripts/test_product_offline.py
```

第二条命令需要已准备 `tiny.en` 和 `base.en`，并允许 CoreML 硬件访问；它包含真实推理和网络禁止策略验证。原生 `--self-test` 不打开摄像头或操作鼠标。最后一条验证真实 OCR → Argmax → Bonsai → 移动指令链路，使用合成音频与生成图像，不操作系统鼠标。

- [产品交互说明](docs/PRODUCT.md)
- [系统架构与数据边界](docs/ARCHITECTURE.md)
- [断网验收与比赛演示脚本](docs/DEMO.md)
- [已验证范围与复现方法](docs/VERIFICATION.md)
- [独立语音模块的离线安装](docs/OFFLINE_SETUP.md)

技术依赖：[Argmax WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)、[Apple Vision](https://developer.apple.com/documentation/vision)、本机安装的 PrismML Bonsai-2 与 LM Studio MLX 运行时。
