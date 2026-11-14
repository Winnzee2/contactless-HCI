# 本机桌面控制架构 / Local desktop architecture

`desktop.py` 是产品启动器；`src/stt` 是独立的纯转写库。桌面控制层复用 STT 的输出，同时保留 `cli.py`、`main.py` 的转写接口。

## 数据流

```text
Camera → Apple Vision hand landmarks → index pointer / deliberate pinch clicks

Microphone → local PCM clip → Argmax Swift CLI → plain transcript ──┐
                                                                  ├→ Bonsai-2 2B → selected OCR ID
Pointer-area screenshot → Apple Vision OCR → candidate labels/IDs ─┘
                                                                         ↓
                                                known coordinates → pointer move + lock
```

**语音路径不执行点击。** 左键来自拇指与中指捏合，右键来自拇指与无名指捏合。语音定位后前 3 秒忽略食指位移；捏合点击可立即完成并清除锁定。3 秒后明显移动手部会解除锁定，手保持稳定则继续锁定。暂停和跟踪丢失始终立即清除锁定。

## 组件

| 文件或模块 | 职责 |
| --- | --- |
| `desktop.py` | 检查/启动本机组件、管理进程、转发事件与关闭资源 |
| `native/GestureCamera.swift` | AppKit 窗口、摄像头与麦克风采集、Vision 手部识别、局部屏幕 OCR、鼠标事件 |
| `src/control/coordinator.py` | 将录音与原始指针区域绑定，管理请求 ID、状态、有效期和目标坐标 |
| `src/control/worker.py` | 对录音执行 Argmax 转写，再交给 Bonsai 选择 OCR 目标 |
| `src/control/bonsai.py` | 限制为本机模型接口，验证候选、模型 JSON 和返回目标 ID |
| `src/stt` | 本地模型检查、文件/PCM/麦克风转写；无鼠标或手势行为 |
| `scripts/start_bonsai.sh` / `scripts/serve_bonsai.py` | 用已经安装的 MLX 运行时和 Bonsai 权重提供本机推理 |
| `scripts/build_gesture_app.sh` | 通过本地 Swift SDK 编译 `.build/LocalControl.app` |
| `scripts/build_product.sh` / `native/ProductLauncher.swift` | 构建 Finder 启动器 `.build/Local Control.app`，从已准备的项目位置启动 `desktop.py` |

## 进程与线程

Python 启动器、原生窗口、语音/模型工作进程通过 JSON Lines 管道交换消息。语音工作与摄像头/UI 分开，避免转写期间阻塞手部追踪。截图 OCR 使用原生后台队列。

Bonsai 在 `http://127.0.0.1:1234/v1` 提供本地 OpenAI-compatible 接口，模型 ID 为 `bonsai-local`。这仅是 API 格式，不表示调用 OpenAI 云服务。

Argmax 使用 `whisperkit-cli transcribe` 加显式模型/tokenizer 路径，经标准输入/输出和临时音频文件完成调用。这里**没有使用 Argmax Local Server API**。

## 目标绑定

语音开始时，协调器记录指针位置并请求附近 720 × 420 屏幕点的 OCR。每个文本候选包含内部 ID、标签和本机已知的包围框。候选文字/ID与转写发送给 Bonsai；包围框坐标留在协调器。

Bonsai 只能返回给定候选中的 ID 或空结果。请求时把原始 OCR ID 映射为简短的请求内编号，所有候选仍发送给模型；只有通过校验的编号才映射回原始 OCR 目标，坐标不由模型提供。这样减少小模型丢失 ID 前缀或把标签当作 ID 的错误。

返回内容经过大小、类型、字段和 ID 校验；模型生成的坐标、未知 ID 或额外操作不会被接受。重复匹配标签、否定或假设性语句，以及选中的标签没有在语音中明确出现时，不移动指针。只有大小写和标点不同的明确标签可以按屏幕上的拼写发送，仍须由 Bonsai 返回有效选择。

协调器只应用当前控制状态中的有效请求。暂停、手部追踪失效、过期结果或不在原始区域中的候选会使定位失效。原生层再次检查屏幕边界、控制状态和请求，最后移动并锁定指针。

原生 `TargetLock` 保存目标坐标、定位时的手部锚点和 3 秒保护截止时间。保护期内食指位移不改变目标位置；保护期结束后，相对锚点的明显位移才释放锁定。新的语音定位重新开始保护期；手势点击、暂停和手部跟踪丢失可立即清除它。

OCR 识别的是可见文字，不能证明文字本身对应可点击控件。用户通过手势决定是否点击。

## 离线边界

- 摄像头、手部模型、屏幕 OCR 使用 macOS 自带的 AVFoundation / Vision / ScreenCaptureKit。
- Argmax 进程通过 macOS sandbox policy 禁止网络访问；模型缺失时失败，不回退到下载。
- Bonsai 使用已安装的 `Ternary-Bonsai-2-2B-mlx-2bit` 与 LM Studio MLX 运行时。启动脚本启用离线模式，并禁止外网，只允许本机回环通信。
- 客户端拒绝非回环 URL、HTTP 重定向和环境代理；无云端备用路径。
- Git 中不包含模型权重和 `.build`。新机器必须先准备兼容依赖与模型。
- Finder 启动器记录项目的绝对位置，模型和运行时仍位于项目或用户缓存；它不是独立安装包。移动项目后需要重新构建启动器。

`python3 desktop.py --check` 检查资产和已运行的服务，不代替摄像头/麦克风/屏幕/点击的真人测试。完整离线验收必须在关闭 Wi-Fi 后从新进程启动，并操作实际目标应用。

## macOS 权限

摄像头与麦克风权限允许本地采集，辅助功能权限允许指针操作，屏幕录制权限允许取得 OCR 输入。用户通过 macOS 系统设置授权。应用无法绕过这些权限，也不会把授权成功当作真人识别测试已经完成。

## 实测边界

Wi-Fi 关闭时，真实摄像头、真实屏幕 OCR 和生成输入驱动的 Argmax → Bonsai → 控制器链路已通过检查。另一次 Wi-Fi 开启的真人测试完成了本地验收板上的 `Codex` 定位后左右键，以及 `Safari` 定位后左键；日志记录语音移动与手势点击使用相同坐标。两组证据不能合并成已经完成 Wi-Fi 关闭的真人连续演示。3 秒目标保护另由原生逻辑测试覆盖，详见 [验证记录](VERIFICATION.md)。
