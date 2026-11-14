# Local Control 产品说明

## 使用目标

让用户在一台 Mac 上完成“指向 → 定位 → 点击”：手势负责持续移动和点击，语音帮助把指针精确移到附近的可见文字。所有识别和推理均使用本机组件，准备完成后可关闭 Wi-Fi。

English: Hand gestures control movement and clicking. Speech names a nearby visible label and helps position the pointer. Speech never executes a click.

## 核心交互

1. 在 Finder 双击项目中的 [Local Control.app](<../.build/Local Control.app>)；也可运行 `open ".build/Local Control.app"`、`python3 desktop.py` 或双击 `Launch Local Control.command`。命令均从项目目录执行。
2. 授予摄像头、麦克风、辅助功能、屏幕录制权限；必要时重启程序。
3. 初始处于 PAUSED。在控制窗口点击 Enable pointer，或按空格开启。
4. 伸出食指，把指针移到要操作的区域附近。
5. 直接用拇指和中指捏合执行左键；用拇指和无名指捏合执行右键。
6. 需要文字辅助定位时，说出附近的目标，例如“Codex”或“打开 Codex 那个标签”。短暂停顿，让本地语音转写和模型选择完成。
7. 指针移动到选中的文字位置并锁定。前 3 秒忽略食指移动，方便准备捏合；点击后立即解除锁定。3 秒后明显移动手部可解除锁定，手保持稳定时继续锁定。
8. Escape 暂停；控制窗口中的 Q 或关闭窗口退出。

捏合需要先松开再重新合拢，避免持续保持同一手势时重复点击。暂停或失去可靠手部追踪后，立即清除锁定并拒绝延迟返回的旧定位结果，3 秒保护期也不例外。

English: Open `.build/Local Control.app`, grant the four macOS permissions, and enable the pointer in the preview window. If the app has not been built, run `bash scripts/build_product.sh` after preparing the local dependencies and models. `python3 desktop.py` remains the command-line entry point.

## 语音定位的含义

用户说“Codex”，不是把这句话变成系统命令。处理过程如下：

- Argmax 将当前录音转写成普通文字。
- macOS OCR 识别语音开始时指针附近约 720 × 420 屏幕点的可见文本。
- Bonsai-2 2B 根据转写，从 OCR 列表中选择一个目标 ID。
- 控制器取回该 ID 的已知坐标，让指针移到那里。

模型不能提供任意坐标或鼠标操作。即使说“点击 Codex”，语音定位也只移动指针；点击由手势完成。

## 状态与反馈

| 状态 | 用户看到或可以做的事 |
| --- | --- |
| PAUSED | 预览可见，指针控制停止；在控制窗口开启 |
| ENABLED | 食指控制指针，捏合可点击 |
| 本地语音处理中 | 保持目标区域稳定；等待转写与选择 |
| Target: … | 指针已定位；前 3 秒不受食指移动影响，捏合可立即点击；之后明显移动手部可继续跟随 |
| 无匹配、重复文字或权限错误 | 显示原因；不猜测并执行另一个目标 |

麦克风采集由原生层负责，应用只把当前交互的音频传到本机 Argmax 进程。屏幕图像由本机 OCR 处理，Bonsai 接收的是候选文字和 ID，不接收整张屏幕截图。

## 原型范围

当前支持主显示器上的局部文字定位和基础鼠标控制。它不会自动导航网页，不会寻找隐藏窗口，也不能仅凭图标或对象外观理解“那个东西”。同名候选无法唯一定位时返回无匹配；用户应移动到更明确的位置或改变可见内容。

本产品与独立语音 API 的职责保持分开：`src/stt` 只做音频到文字；桌面控制层负责把语音文字与 OCR 候选组合。已有的 `cli.py` 与 `main.py` 仍保持纯转写用法。

## 离线约束

- 必须提前准备 Argmax CLI、多语言 Whisper base、tokenizer、Bonsai-2 2B 和兼容的本地 MLX 运行时。
- 运行期间不下载模型，不调用云端转写或远程语言模型，不加载浏览器 CDN。
- Bonsai 服务只监听本机回环地址；Wi-Fi 关闭不影响这种进程间通信。
- 不同设备上的首次安装仍需要事先取得依赖，或从准备好的设备本地转移。
- `.build/Local Control.app` 启动的是当前已准备的项目。模型和运行时保留在项目或用户缓存目录中；这不是可以单独复制到另一台 Mac 的完整安装包。项目移动后需要重新构建启动器。

## 当前验证状态

2026-11-14 在目标 Mac 上实际关闭 Wi-Fi 后，摄像头检查处理了 30 帧，其中 1 帧检测到手部，Vision 失败数为 0；真实屏幕 OCR 以 Retina 分辨率读取局部区域。生成图像中的 `Codex`、`Safari`、`Finder` 经过 OCR，合成语音经过真实 Argmax 和 Bonsai，控制器输出了 `Codex` 的准确移动坐标。测试结束后 Wi-Fi 已恢复。

另一轮 **Wi-Fi 开启**的真人测试中，说 `Codex` 后指针实际移到目标，同一坐标的手势左键、右键均有记录；说 `Safari` 后也完成定位与手势左键。本地浏览器验收板记录了实际点击。该次运行也出现过模型选择无效并被拒绝的请求；后续已调整候选编号和校验，并通过真实 OCR 候选回放检查。成功记录不代表所有请求或所有应用都已验证。

真人测试与前面的 Wi-Fi 关闭组件检查是两组不同证据；后者的模型链路截获指令，没有向操作系统发送鼠标操作。3 秒保护期另有原生逻辑回归检查。完整的断网真人演示视频尚未录制，详见 [验证记录](VERIFICATION.md) 和 [演示指南](DEMO.md)。
