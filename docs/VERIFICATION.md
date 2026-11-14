# 离线验证记录与复现

## 已完成的 Wi-Fi 关闭实测

**2026-11-14**，在这台 Mac 上实际关闭 Wi-Fi 后完成以下检查，结束后恢复 Wi-Fi：

| 检查 | 实际结果 |
| --- | --- |
| Wi-Fi 状态 | 开始 `On` → 检查期间 `Off` → 结束 `On` |
| 真实摄像头与 Vision | 处理 30 帧，1 帧检测到手部，Vision 失败数为 0 |
| 真实屏幕局部 OCR | 通过；720 × 420 屏幕点对应 1440 × 840 像素，保留 Retina 文字细节 |
| 本地模型链路 | 生成图像 OCR → 合成语音 → Argmax → Bonsai → 控制器通过，选中 `Codex` |
| 模型链路最终指令 | 唯一指令为 `move_to`，坐标与原始 OCR 候选完全一致；没有发送系统鼠标操作 |
| 推理网络策略 | Argmax 和 Bonsai 的外部 socket 连接均被禁止；Bonsai 使用本机回环连接 |

本地证据位于 `.build/verification/wifi-off/`：`summary.json`、`wifi-before.txt`、`wifi-during.txt`、`wifi-after.txt` 和 `pipeline/offline-pipeline.json`。这些是本机诊断资料，保留在被 Git 忽略的 `.build` 中；真实屏幕文字不复制到仓库文档。

摄像头和屏幕检查没有发送鼠标操作。1 帧手部检测只说明 Vision 已在真实摄像头输入上检测到手，并不代表持续跟踪质量已经验收。此前实时运行记录到了左右键手势事件和麦克风转写事件，但**尚未完成“真人说 Codex → 指针实际移到标签 → 真人捏合点击”的连续验收**。

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

目前已分别验证真实摄像头、真实屏幕 OCR 和真实本地模型链路；完整的真人语音定位与手势点击连续操作仍按 [DEMO.md](DEMO.md) 验收。

## 自动回归测试

2026-11-14，`STT_INTEGRATION=1 python3 -m unittest discover -s tests -v` 的 **71 项检查全部通过**，包括真实 Argmax 推理。原生算法检查 **18 项全部通过**。最后的界面状态提示修改后，普通回归再次通过（69 项通过、2 项原生推理检查按默认配置跳过）。

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

已实际双击启动器，确认摄像头预览和麦克风初始化成功；也通过命令行启动实测了手部骨架显示、暂停按钮和退出清理。macOS 会按启动来源分别授权：独立 `.app` 的指针启用检查仍提示需要辅助功能权限，不能把命令行环境中四项权限已通过的结果当作 `.app` 已全部授权。首次使用或重新构建后，按系统提示为对应的 Local Control 应用授权并重启。该权限属于系统设置，应用不会修改权限数据库来绕过它。

受限的开发沙箱可能阻止 CoreML/Metal 或嵌套 macOS sandbox 初始化。此时在普通终端运行以上命令，不要把沙箱限制误报为模型缺失。
