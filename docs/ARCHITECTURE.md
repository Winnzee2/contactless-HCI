# 本机桌面控制架构 / Local desktop architecture

`desktop.py` 是产品启动器；`src/stt` 是独立的纯转写库。桌面控制层复用 STT 的输出，同时保留 `cli.py`、`main.py` 的转写接口。

## 数据流

```text
Camera → Apple Vision hand landmarks → index pointer / deliberate pinch clicks

Microphone → local PCM clip → Argmax Swift CLI → plain transcript ─────┐
                                                                      ├→ named candidates → Bonsai-2 2B
Pointer area → macOS Accessibility + Vision OCR → candidate labels/IDs ┘
                                                                            ↓
                                             unique valid ID → pointer move + lock
                                             multiple matches → numbered circles
                                                                            ↓
Spoken number → Argmax → local number parser → fresh target checks → pointer move + lock
```

**语音路径不执行点击。** 左键来自拇指与中指捏合，右键来自拇指与无名指捏合。语音定位后前 3 秒忽略食指位移；捏合点击可立即完成并清除锁定。3 秒后明显移动手部会解除锁定，手保持稳定则继续锁定。暂停和跟踪丢失始终立即清除锁定。

## 组件

| 文件或模块 | 职责 |
| --- | --- |
| `desktop.py` | 检查/启动本机组件、管理进程、转发事件与关闭资源 |
| `native/GestureCamera.swift` | AppKit 窗口、摄像头与麦克风采集、Vision 手部识别、局部屏幕 OCR、鼠标事件 |
| `native/ScreenTargets.swift` | 只读 Accessibility 与本机 OCR 目标发现、去重、标签与屏幕坐标校验 |
| `native/DuplicateTargetOverlay.swift` | 不接收点击、不抢占焦点的目标圆圈、数字标签与固定过期时间 |
| `src/control/coordinator.py` | 将录音与原始指针区域绑定，管理请求 ID、状态、有效期和目标坐标 |
| `src/control/worker.py` | 对录音执行 Argmax 转写，再按请求类型交给 Bonsai 或本机编号解析器 |
| `src/control/bonsai.py` | 限制为本机模型接口，验证候选、模型 JSON 和返回目标 ID |
| `src/control/number_choice.py` | 只解析当前编号选择中的完整数字语句或取消语句，不生成坐标或点击 |
| `src/stt` | 本地模型检查、文件/PCM/麦克风转写；无鼠标或手势行为 |
| `scripts/start_bonsai.sh` / `scripts/serve_bonsai.py` | 用已经安装的 MLX 运行时和 Bonsai 权重提供本机推理 |
| `scripts/build_gesture_app.sh` | 通过本地 Swift SDK 编译 `.build/LocalControl.app` |
| `scripts/build_product.sh` / `native/ProductLauncher.swift` | 构建 Finder 启动器 `.build/Local Control.app`，从已准备的项目位置启动 `desktop.py` |

## 进程与线程

Python 启动器、原生窗口、语音/模型工作进程通过 JSON Lines 管道交换消息。语音工作与摄像头/UI 分开，避免转写期间阻塞手部追踪。截图 OCR 使用原生后台队列。

Bonsai 在 `http://127.0.0.1:1234/v1` 提供本地 OpenAI-compatible 接口，模型 ID 为 `bonsai-local`。这仅是 API 格式，不表示调用 OpenAI 云服务。

Argmax 使用 `whisperkit-cli transcribe` 加显式模型/tokenizer 路径，经标准输入/输出和临时音频文件完成调用。这里**没有使用 Argmax Local Server API**。

## 目标绑定

语音开始时，协调器记录指针位置并请求附近 720 × 420 屏幕点的 Accessibility 与 OCR 目标。每个候选包含内部 ID、标签和本机已知的包围框。控制层根据明确说出的名称筛选候选，保留原始标签、ID 与全部匹配的重复目标。筛选支持通用中英文名称与请求表达，不依赖特定网站或目标名称列表；不相关的屏幕说明文字不再进入模型上下文，因此不会像原本的离线目标板问题那样干扰正确识别的名称。

Bonsai 只能返回给定候选中的 ID 或空结果。请求时把筛选后的原始 ID 映射为简短的请求内编号；只有通过校验的编号才映射回原始目标。模型仅收到转写、ID 与标签，坐标始终留在控制层，不由模型提供。名称筛选不替代模型：唯一目标仍需 Bonsai 返回有效 ID，模型返回空结果时不会通过确定性后备逻辑直接移动指针。

返回内容经过大小、类型、字段和 ID 校验；模型生成的坐标、未知 ID 或额外操作不会被接受。否定、假设性语句或没有明确命名可见目标时不移动指针。多个名称匹配目标只产生编号选择，不自动决定位置。Bonsai 的响应仍须通过格式及 ID 校验；无效响应不会打开选择列表。

协调器只应用当前控制状态中的有效请求。暂停、手部追踪失效、过期结果或不在原始区域中的候选会使定位失效。原生层再次检查屏幕边界、控制状态和请求，最后移动并锁定指针。

### 重复目标的编号选择

多个匹配目标按屏幕从上到下、从左到右排列，每个目标显示圆圈与 `1…N` 编号。选择会话保存不可变的原始区域、标签、几何位置、编号与请求代次；只有原生层确认圆圈已经显示后才接收后续编号语音。指针不会因出现重复匹配而移动，编号也不会随手部移动重新排序。所有匹配的附近候选都会列出，受单次目标发现的候选上限约束。

用户保持手部可见并说出 “two”、“number two” 或 “第二个”等完整编号语句。Argmax 仍只做语音转文字；`number_choice.py` 将文本映射到当前显示列表的编号，不需要第二次语义模型选择。它拒绝越界、否定、含多个编号或对话中的数字；“cancel” 或“取消”会关闭选择。任何编号都不能产生点击或提供任意坐标。

选择固定在显示请求发出后 **15 秒**过期，无效编号不会延长时间。暂停、跟踪丢失、捏合或握拳意图、鼠标点击、滚动、按键、前台应用切换或桌面 Space 切换会清除选择及在途结果。旧请求、旧显示确认或旧取消事件不能影响新会话。

后续编号录音重新捕获最初的区域，截图时临时隐藏覆盖层。协调器按规范化标签与相近包围框，把每个原始编号一对一绑定到新发现的目标；缺失、移动过远、重复或复用同一目标时取消。Argmax 转写完成后，原生层在实际移动前再次确认选定目标、当前应用上下文、手部状态和截止时间。成功后先清除数字圆圈，再移至重新确认的目标并启动原有的三秒保护。只有手势路径可以点击。

离线练习页 [duplicate-targets.html](../assets/demo/duplicate-targets.html) 提供三个同名按钮；[target-board.html](../assets/demo/target-board.html) 提供不同名称的目标。两者都是普通本机页面，生产代码没有页面专用选择器或网络依赖。

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
