# 断网验收与两分钟演示

这份清单用于完成连续操作验收和录制演示。2026-11-14 已在这台 Mac 上实际关闭 Wi-Fi，验证摄像头、真实屏幕 OCR，以及生成图像与合成语音经过真实 Argmax、Bonsai、控制器的链路；检查结束后恢复了 Wi-Fi。详细证据见 [验证记录](VERIFICATION.md)。

真人说出目标、指针实际定位、随后捏合点击的完整连续流程仍需按下表完成。下面的视频脚本是待录制计划，不表示已经有可提交的视频。

## 录制前准备

1. 准备这台 Mac 的本地 Argmax 多语言 `base` 模型和 tokenizer、Bonsai-2 2B 权重与兼容 MLX 运行时。
2. 在项目目录运行 `bash scripts/build_product.sh`，构建原生程序和 Finder 启动器。
3. 双击 [Local Control.app](<../.build/Local Control.app>) 或运行 `open ".build/Local Control.app"`，在系统设置中授予摄像头、麦克风、辅助功能和屏幕录制权限；需要时完全退出重启。命令行备用入口是 `python3 desktop.py`。
4. 准备一个无需联网的目标窗口，例如已有本地内容的应用。选择足够大、唯一、清晰可见的标签；演示“Codex”时确保该文字在目标区域内，且没有重复候选。
5. 把控制预览窗口移到不会遮挡目标的位置。测试时避免把指针停在会造成意外操作的位置。
6. 完全退出 Local Control 及本次演示启动的 Bonsai 服务，然后关闭 Wi-Fi。若有有线网络，也断开它。保留系统所需权限。
7. 重新打开 `.build/Local Control.app` 或运行 `python3 desktop.py`，确认应用可从本地启动模型与推理。

Bonsai 本地服务地址 `127.0.0.1` 不需要 Wi-Fi。模型只需在准备阶段取得；运行期间不应出现下载要求。程序若提示缺失依赖，应回到准备阶段解决，不要在录制中跳过。

English: Prepare the local models and runtime, run `bash scripts/build_product.sh`, and open `.build/Local Control.app`. Grant Camera, Microphone, Accessibility, and Screen Recording permissions. Quit the product, turn Wi-Fi off, and reopen it before recording. The app starts paused; click **Enable pointer** to begin. Keep the project and model/runtime folders in place: the `.app` launches the prepared project and is not a standalone portable bundle.

## 本人验收清单

| 测试 | 预期结果 |
| --- | --- |
| 断网后新启动 | 摄像头窗口打开，模型就绪，默认 PAUSED |
| 开启后移动食指 | 主显示器的鼠标跟随，方向符合镜像预览 |
| 拇指 + 中指 | 左键单击；保持合拢不会连续点击 |
| 拇指 + 无名指 | 右键单击；松开后可再次触发 |
| 指向标签附近，说“Codex” | 显示转写和目标，指针移动到对应可见文字 |
| 语音定位后不做点击手势 | 指针保持定位，不自动点击 |
| 定位后明显移动手部 | 解除锁定，恢复食指跟随 |
| 定位后用点击手势 | 在锁定位置点击，然后恢复移动 |
| 说出区域内不存在的名称 | 不跳到一个凭空猜测的位置 |
| 出现重复同名标签 | 不选择一个含糊目标 |
| Escape / 暂停 | 停止指针控制，旧语音结果不会随后生效 |
| Q 或关窗 | 退出窗口，摄像头和麦克风停止使用 |

关闭录音或不授权麦克风时可用 `python3 desktop.py --gesture-only` 单独检查手势。该模式不使用 Bonsai/Argmax，因此不能单独作为完整比赛方案的演示。

## 两分钟以内的视频脚本

建议录制约 **1 分 45 秒**，留出片头和剪辑余量。

| 时间 | 画面与操作 | 简短旁白 |
| --- | --- | --- |
| 0:00–0:12 | 展示 Wi-Fi 关闭与本地应用启动 | “Local Control 用手势和语音控制本机指针，推理完全在 Mac 上。” |
| 0:12–0:30 | 开启控制，食指移动指针 | “食指负责连续移动。摄像头手部识别在本机完成。” |
| 0:30–0:48 | 中指捏合左键，再演示无名指捏合右键 | “拇指配合中指是左键，配合无名指是右键。” |
| 0:48–1:15 | 指到标签附近，说“Codex”；展示转写与指针定位 | “Argmax 把语音变成文字。附近的屏幕文字经过本地 OCR，再由 Bonsai-2 2B 选择目标。” |
| 1:15–1:30 | 先不点击，展示锁定；再手势点击 | “语音只定位，点击仍由手势决定。” |
| 1:30–1:45 | Escape 暂停，展示模型/项目说明 | “本地权重、本地语音、本地模型服务。关闭 Wi-Fi 仍可使用。” |

English pitch: “Local Control combines hand tracking with voice-assisted pointer targeting. Argmax transcribes the user’s speech, Bonsai-2 selects a nearby OCR label, and a deliberate hand gesture performs the click. It runs on an Apple Silicon Mac with Wi-Fi off.”

不要用剪辑暗示未成功的识别已经完成；若目标找不到或存在歧义，展示实际提示并调整目标区域。

## 提交材料

根据本次比赛提供的 kickoff slides 与 technical details：

- 截止：**2026 年 11 月 15 日中午 12:00，纽约当地时间**。
- 需要使用允许的 **Bonsai-2 2B / 4B / 9B** 之一，以及 **Argmax**；当前方案使用 Bonsai-2 2B 和 Argmax WhisperKit。
- 在 Mac 上关闭 Wi-Fi 运行。
- 提交本人和队友姓名、一句话介绍、GitHub 链接、**少于两分钟**的运行视频。
- 按主办方要求提交到 `#submissions`；最多两人一组。

可编辑的一句话介绍：

> Local Control is an offline accessibility prototype that combines hand gestures, Argmax speech recognition, and Bonsai-2 to target visible screen text and control the mouse on a Mac.

代码仓库：[Winnzee2/local-AI-argmax](https://github.com/Winnzee2/local-AI-argmax)。录制前确认仓库已包含最终实际演示版本；本地未提交修改不等于已经推送。

本项目开发使用过托管的 Codex，因此不能声称符合“完全使用本地 AI 编写”的 Locally Made bounty 条件。产品在运行时离线与开发工具是否本地，是两个不同的事实。

本文件不会替你录制、上传、发消息或提交比赛材料。
