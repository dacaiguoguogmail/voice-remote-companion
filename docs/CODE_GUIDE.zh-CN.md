# 中文代码导读

[English](CODE_GUIDE.md) | 简体中文

这份文档用于理解工程内部实现。先阅读这里的三条调用链，再对照各文件中的中文注释。安装和日常使用请看项目根目录的 [中文 README](../README.zh-CN.md)。

## 1. 项目各文件做什么

| 文件 | 用途 |
| --- | --- |
| `Phone/PhoneApp.swift` | iPhone 的应用入口、设备发现、TCP 连接、麦克风采集、界面和手机端反馈。 |
| `Mac/MacApp.swift` | Mac 的应用入口、Bonjour 广播、接收和配对、音频播放、快捷键模拟及设置窗口。 |
| `Shared/Wire.swift` | 两端共同使用的 `Message` 结构和 `Wire` TCP 收发封装。 |
| `Phone/DiscoveryInfo.plist` | 声明手机要浏览的 Bonjour 服务类型。 |
| `Mac/DiscoveryInfo.plist` | 声明 Mac 要发布的 Bonjour 服务类型。 |
| `Companion.xcodeproj/project.pbxproj` | Xcode 工程配置：应用目标、源码、iOS/macOS 平台、签名和权限提示。它是配置数据，没有业务方法；通常应通过 Xcode 修改。 |
| `.gitignore` | 告诉 Git 忽略本地构建产物、Xcode 用户状态等文件，不影响运行逻辑。 |
| `README.md` / `README.zh-CN.md` | 英文及中文安装、使用、故障排查和安全边界。 |
| `docs/CODE_GUIDE.md` / `docs/CODE_GUIDE.zh-CN.md` | 本文：解释文件职责、调用链、数据格式和阅读顺序。 |

`Build/` 和 Xcode 生成的临时文件不在 Git 中，不属于需要逐个阅读的源码。工程中主要逻辑集中在三个 Swift 文件，没有单独的服务器项目。

## 2. 一次连接是怎样建立的

1. 启动 Mac 应用：`MacApp` 创建 `MacModel`，其 `init()` 刷新音频设备、网络地址，并调用 `start()`。
2. Mac 的 `start()` 在 TCP 端口 `45971` 监听，同时通过 Bonjour 发布 `_voiceremote._tcp` 服务，服务名通常是 Mac 名称。
3. 手机的 `PhoneApp` 创建 `PhoneModel`；`RemoteView` 出现时调用 `startDiscovery()` 浏览该服务。
4. `connectDiscoveredIfAvailable()` 在前台且没有连接时，优先使用之前选中的唯一同名服务；否则在只发现一条记录时自动连接。多条记录需要在设置里选择。
5. 用户也可以在设置中输入 IP，`connect()` 会保存该地址，并在本次运行中用它作为手动重试目标。
6. 手机的 `connect(to:)` 创建 `NWConnection` 并交给 `Wire`。TCP 准备好后发送 `auth` 消息，`value` 是配对码。
7. Mac 的 `accept(_:)` 暂存待配对连接；`handle(_:from:)` 检查配对码。成功后新连接接替旧连接，Mac 返回 `ready`，手机才将 `connected` 设为 `true`。
8. 手机侧断线后等待三秒再重试；连接或配对八秒没有完成则取消。`attempt` 和连接对象身份检查使旧的异步回调不会覆盖新连接。

Bonjour 只负责发现服务，实际数据使用 TCP；它不保证所有热点都能传播发现信息。自动发现失败时仍可手动输入可互通的 Mac 地址。

## 3. 按住说话到输入文字

```text
手指按住手机语音键
  → PhoneModel.startVoice()：请求麦克风权限
  → PhoneModel.beginCapture()：配置音频会话、安装采集回调
  → voice_start / audio：通过 Wire 发给 Mac
  → MacModel.startVoice() / play(_:)：向选择的音频设备播放
  → BlackHole 2ch：把播放输出提供为虚拟输入
  → Wispr Flow 等工具：识别语音并向当前输入框插入文字
```

松手后，手机 `stopVoice()` 停止采集并发送 `voice_stop`。Mac 的 `stopVoice(immediate:)` 通常会等待已排队音频播放完，再松开模拟的 Ctrl/Fn；如果断线则立即清理。三秒兜底回调用于防止播放完成通知丢失后按键一直处于按下状态。

### 手机端采样细节

- `startVoice()` 先标记录音并请求权限。权限请求是异步的；`captureGeneration` 可避免用户已经松手或开始新会话后，旧回调又错误启动录音。
- `beginCapture()` 先尝试 `.record` / `.measurement` 音频会话；失败后再尝试可混音的 `.playAndRecord` 配置。
- 输入采样通过 `AVAudioConverter` 转成 **16 kHz、单声道、有符号 16 位 PCM**。每块数据计算均方根音量，供手机进度条显示；原始字节转成 Base64 后放进 `audio` 消息。
- `voice_start` 在启动采集引擎之前发送；引擎启动失败时会发送 `voice_stop` 并把错误显示在手机上。

### Mac 端播放细节

- `startVoice()` 根据所选设备创建 `AVAudioEngine` 和 `AVAudioPlayerNode`，设置输出设备并启动播放；根据用户设置模拟按下 Ctrl 或 Fn。
- `play(_:)` 校验数据长度，把 16 位采样复制到 PCM 缓冲区并排队播放，同时估算接收音量和累计帧数。`audioFrames / 16000` 是本次接收时长的估计。
- 音量条表示采集或接收到音频，并不能单独证明 Wispr Flow 已识别成功。识别由外部工具完成，本工程不产生或存储识别文本。

## 4. 按键怎样到达 Mac

1. `RemoteView` 中的 `RemoteKey` 在点击时调用 `PhoneModel.command(_:)`。
2. 手机发送 `type: command`，`value` 是例如 `return`、`backspace`、`copy` 或 `chat_1` 的字符串；随后显示震动、短提示和提示音。
3. Mac 的 `handle(_:from:)` 将消息交给 `MacModel.command(_:)`。
4. 聊天命令映射为 Command + 数字；`codex` 根据应用的 Bundle ID 打开应用；其余受支持命令通过 `CGEvent` 发送按键及修饰键。
5. 按键作用于 Mac **当前前台应用**，执行效果由该应用决定；模拟按键需要辅助功能权限。

系统聊天 Picker 的绑定每次都读取占位值，选择 1–9 时立即发一次快捷键，所以同一数字也能连续发送。它没有读取 Codex 当前选中的聊天，界面不能据此断言哪条聊天正在显示。

## 5. 通信消息与分帧

`Message` 只有 `type` 和可选 `value` 两个字段，采用 JSON 编码；`Wire.send(_:)` 在每条 JSON 后添加一个换行。TCP 是字节流，一次接收不一定正好是一条消息，所以 `Wire.receive()` 先累积字节，再按换行拆出完整消息并解码。

| `type` | 方向 | `value` 的含义 |
| --- | --- | --- |
| `auth` | 手机 → Mac | 配对码。 |
| `ready` | Mac → 手机 | 通知配对完成；通常没有 `value`。 |
| `voice_start` | 手机 → Mac | 开始一次语音会话；通常没有 `value`。 |
| `audio` | 手机 → Mac | PCM 音频字节的 Base64 字符串。 |
| `voice_stop` | 手机 → Mac | 结束语音会话；通常没有 `value`。 |
| `command` | 手机 → Mac | 遥控命令名称。 |
| `error` | Mac → 手机 | 展示给用户的错误说明。 |

接收缓冲区超过 256 KiB 时连接会被取消；无法解码的单条消息会被跳过。这个协议目前是项目内部协议。

## 6. SwiftUI 与异步状态怎么看

- `@StateObject`：应用入口创建并持有模型。`@ObservedObject`：界面接收模型并观察变化。`@Published`：模型属性变化时通知界面更新。
- `@MainActor`：手机和 Mac 的模型状态在主线程维护。网络、权限和音频处理可能在其他队列回调，因此相关代码通过 `Task { @MainActor in ... }` 或主队列更新界面。
- `[weak self]` / `[weak w]`：闭包弱引用对象，避免异步任务长期保留模型或旧连接；回调执行时对象可能已经消失，需要 `guard`。
- `captureGeneration`、Mac 的 `generation` 和手机的 `attempt`：分别用来识别过期的录音回调、播放结束回调和重连任务，避免旧操作影响新会话。
- `RemoteView.body` 根据可用高度计算按钮高度，语音和回车在底部并排；面向当前需求的 iPhone 13 单屏布局，其他尺寸仍需另行验证。

## 7. 从哪里开始修改

- 修改按钮排列或文案：读 `Phone/PhoneApp.swift` 的 `RemoteView`、`chatPicker(height:)`、`RemoteKey`。
- 增加一个遥控命令：同时检查手机 `command(_:)` 的反馈名称，以及 Mac `command(_:)` 的命令映射；需要时更新 README 的快捷键表。
- 修改音频格式：同时修改手机 `beginCapture()` 与 Mac 的 `format`、音量计算及帧数换算，确保两端一致。
- 排查配对或自动发现：查看手机 `startDiscovery()` / `connect(to:)` 和 Mac `start()` / `accept(_:)` / `handle(_:from:)`。
- 修改权限说明、系统版本或签名：查看 `Companion.xcodeproj/project.pbxproj` 和两个 Bonjour plist；不要把签名证书或个人凭据提交到仓库。

当前配对码、TCP 音频和命令均未加密，仅适合可信局域网。Mac 自动生成并保存在应用偏好设置中的配对码并不能防止网络窃听。
