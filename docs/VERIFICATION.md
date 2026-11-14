# 离线验证记录与复现

## 已完成的 Wi-Fi 关闭实测

**2026-11-14**，在这台 Mac 上实际关闭 Wi-Fi 后完成以下检查，结束后恢复 Wi-Fi。包含 3 秒目标保护和最新 Bonsai 选择处理的版本，已于 **23:44:35 UTC** 再次通过同样的检查：

| 检查 | 实际结果 |
| --- | --- |
| Wi-Fi 状态 | 开始 `On` → 检查期间 `Off` → 结束 `On` |
| 真实摄像头与 Vision | 处理 30 帧，1 帧检测到手部，Vision 失败数为 0 |
| 真实屏幕局部 OCR | 通过；720 × 420 屏幕点对应 1440 × 840 像素，保留 Retina 文字细节 |
| 本地模型链路 | 生成图像 OCR → 合成语音 → Argmax → Bonsai → 控制器通过，选中 `Codex` |
| 模型链路最终指令 | 唯一指令为 `move_to`，坐标与原始 OCR 候选完全一致；没有发送系统鼠标操作 |
| 推理网络策略 | Argmax 和 Bonsai 的外部 socket 连接均被禁止；Bonsai 使用本机回环连接 |

本地证据位于 `.build/verification/wifi-off/`：`summary.json`、`wifi-before.txt`、`wifi-during.txt`、`wifi-after.txt` 和 `pipeline/offline-pipeline.json`。这些是本机诊断资料，保留在被 Git 忽略的 `.build` 中；真实屏幕文字不复制到仓库文档。

在已授予摄像头与屏幕录制权限的目标 Mac 上，可用 `bash scripts/test_wifi_off.sh` 复现这组检查；脚本会临时关闭 Wi-Fi，并在结束时恢复原状态。它验证组件和合成输入链路，不自动执行真人捏合操作。

摄像头和屏幕检查没有发送鼠标操作。1 帧手部检测只说明 Vision 已在真实摄像头输入上检测到手，并不代表持续跟踪质量已经验收。这一轮未进行真人语音定位后点击；下文的真人连续测试是在另一轮 Wi-Fi 开启的会话中进行的。

## 已完成的真人连续操作

**2026-11-14，Wi-Fi 开启时**，用户在真实摄像头和麦克风输入下操作了本地浏览器验收板。控制日志记录以下连续事件：

| 语音与目标 | 语音移动坐标（屏幕点，显示值已四舍五入） | 随后的手势操作 |
| --- | --- | --- |
| `Codex` | `(156.9358523, 321.7910447)` | 左键，原始点击坐标与移动坐标完全相同 |
| `Codex.` | `(156.4534880, 321.7910447)` | 右键，原始点击坐标与移动坐标完全相同 |
| `Safari?` | `(431.9999998, 322.5000003)` | 左键，原始点击坐标与移动坐标完全相同 |

这里的 `move_to` 事件来自语音路径，`click` / `right_click` 事件来自手势路径，已发送给操作系统。运行日志记录了实际操作；浏览器截图显示验收板已选中 `Safari`，左右键计数均为 2。截图计数只作浏览器接收到事件的佐证，不能单独证明输入来自手势，也不等于完整日志中全部事件的总数。

本机证据为 `.build/verification/live-controller.log` 和 `.build/verification/live-board.png`，不提交到 Git。该次日志也包含模型选择无效而被拒绝的请求，包括 `Finder` 尝试；成功记录不代表所有目标都成功或没有错误。

之后修改了 Bonsai 的候选编号和校验：用简短的请求内编号减少 ID 格式错误，只接受模型返回的已知编号，并确认所选标签在语音中被明确提到。使用真实屏幕 OCR 候选的本地模型回放已记录 5 项符合预期的结果；正向目标可以选中，否定语句和未知目标保持不操作。无效输出仍被拒绝，不回退到猜测坐标。这是有限用例的回放结果，不代表任意语句都能识别成功。

上述真人连续测试与前面的 Wi-Fi 关闭组件检查是两次不同的验收，不能合并声称已完成断网真人连续演示。当前覆盖本地验收板上的 `Codex` 和 `Safari`，尚未录制可提交的演示视频。3 秒定位保护是在后续修改中加入，原生回归已覆盖其规则；这些较早的真人日志不用于证明修改后的保护期体验。

## 已验证的软件链路

运行：

```bash
bash scripts/build_product.sh
python3 scripts/test_product_offline.py
```

该脚本使用**真实本地推理**，同时把最终鼠标指令截获到内存，不发送给操作系统：

1. 原生程序生成含 `Codex`、`Safari`、`Finder` 三个标签的图像，用 macOS Vision OCR 取得文字和坐标。
2. 使用本机已安装的 Samantha 语音生成 “Find the Codex tab.”，并转换为 16 kHz、单声道 PCM。
3. 通过产品实际使用的 Python worker，把 PCM 交给本地 Argmax 多语言 `base` 模型转写。
4. 启动独立的 Bonsai-2 2B 本地服务，由模型从 OCR 候选中选出目标 ID。
5. 把真实模型输出交给产品的 `Coordinator`，验证唯一输出为 `move_to`，坐标与 OCR 候选完全一致。
6. 测试 Argmax 和 Bonsai 启动器的网络策略确实拒绝外部 socket 连接；Bonsai 只允许本机回环通信。
7. 退出并清理该脚本自己启动的模型服务，不停止用户已经运行的桌面程序或模型服务。

实际验证于 **2026-11-14** 通过，并在上面的 Wi-Fi 关闭实测中再次通过；生成图像的三个文字候选均被 OCR 识别，模型选中 `Codex`，得到：

```text
Argmax: Find the Codex tab.
Bonsai target: Codex
Captured instruction: move_to (no mouse input was sent)
```

原始证据写入 `.build/verification/offline-pipeline.json`，包括运行时间、模型名称、OCR 候选、转写、模型选择、最终指令和所用原生可执行文件的 SHA-256。每次运行都会重写报告；失败会记录 `passed: false`。`.build` 不纳入 Git。

可用 `--output-dir <folder>` 指定输出目录。该目录还保留合成音频和模型服务日志，便于复现失败。

## 验证边界

这个测试**不会**打开摄像头、录制麦克风、截取真实屏幕、移动鼠标或执行点击。它用合成输入和模拟的手部状态连接真实 OCR、语音模型、Bonsai 和产品控制器。

因此它证明的是：

- 本机安装的 Argmax 与 Bonsai 能实际完成该识别链路；不是通过 mock 模型伪造结果。
- 产品可以把模型选择转换成 OCR 中已有的精确坐标。
- 语音链路输出移动指令，不输出鼠标点击。
- 推理进程的外部网络连接受策略禁止。

这个软件链路脚本本身**不证明**真人手势识别质量、实际麦克风噪声表现、真实屏幕坐标映射或左右键在其他应用中的效果，也不会更改 Wi-Fi 开关。上面的 Wi-Fi 关闭实测由外围检查流程关闭并恢复 Wi-Fi，因此嵌套的 `pipeline/offline-pipeline.json` 中 `wifi_setting_changed: false` 指的是脚本自身未修改开关；实际开关状态以同目录中的前、中、后三份记录为准。

结合上面的独立真人记录，已验证两种目标的语音定位后实际手势点击。不同应用的表现，以及 Wi-Fi 关闭后的连续操作录制，仍按 [DEMO.md](DEMO.md) 复现和验收。

## 自动回归测试

2026-11-14，最终运行 `STT_INTEGRATION=1 python3 -m unittest discover -s tests -v`，**75 项检查全部通过，无跳过，耗时 2.420 秒**，包括真实 Argmax 推理。原生算法检查 **23 项全部通过**，覆盖前 3 秒忽略手指移动、保护期后明显移动释放、稳定手势保持、新目标重置保护期，以及点击/暂停/跟踪丢失可立即清除锁定。随后运行 `scripts/test_wifi_off.sh`，在 Wi-Fi 实际关闭期间再次通过组件和模型链路检查，并恢复 Wi-Fi。

```bash
python3 -m unittest discover tests
```

其中 `tests/test_product_pipeline.py` 验证验收器本身会拒绝缺失、重复、错误记录 ID、未知目标以及 worker 错误结果，不会把这些情况报告为通过。`tests/test_control.py` 验证暂停、手部跟踪丢失、过期结果、候选范围和重复事件处理；`tests/test_bonsai.py` 与 `tests/test_target_selection.py` 验证本地服务边界和模型输出校验。

原生算法与 OCR 的独立检查：

```bash
.build/LocalControl.app/Contents/MacOS/GestureCamera --self-test
.build/LocalControl.app/Contents/MacOS/GestureCamera --ocr-self-test
```

## 环境要求

模型和运行时必须事先存在。验证脚本不下载任何模型或软件。需要：

- 已构建的原生桌面程序；
- Argmax CLI、多语言 Whisper `base` 权重与 tokenizer；
- 本机 Bonsai-2 2B 权重及 `scripts/start_bonsai.sh` 可发现的兼容 MLX 运行时；
- macOS 自带的 `say`（Samantha 语音）、`afconvert` 和 `sandbox-exec`。

`scripts/build_product.sh` 同时生成原生辅助程序 `.build/LocalControl.app` 和可双击的启动器 `.build/Local Control.app`。后者从记录的项目路径启动 `desktop.py`，需要保留项目、本地模型和用户缓存中的 MLX 运行时；它不是独立可转移的完整应用包。移动项目后重新构建。

已实际双击启动器，确认摄像头预览和麦克风初始化成功；也通过命令行启动实测了手部骨架显示、暂停按钮和退出清理。独立 `.app` 起初缺少有效的辅助功能授权；从系统设置移除旧条目并添加准确的 `.build/Local Control.app` 后，已验证窗口可进入 ENABLED 并再次暂停。

随后在系统设置开启该启动器的屏幕录制权限并重新启动，实际运行取得了非空屏幕 OCR 候选并发起 Bonsai 请求；窗口显示 `No confident match. Say visible label again.`，没有屏幕权限错误。这证明启动器的屏幕识别和本地模型路径已运行；该次检查没有证明启动器会话中的正向目标定位成功。当前程序保持暂停状态。

macOS 会按启动来源分别授权，不能把命令行环境中四项权限已通过的结果当作 `.app` 已全部授权。首次使用或重新构建后，按系统提示为对应的 Local Control 应用授权并重启。该权限属于系统设置，应用不会修改权限数据库来绕过它。

受限的开发沙箱可能阻止 CoreML/Metal 或嵌套 macOS sandbox 初始化。此时在普通终端运行以上命令，不要把沙箱限制误报为模型缺失。
