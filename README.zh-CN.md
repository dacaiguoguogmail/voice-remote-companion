# Voice Remote Companion（中文）

一个独立的 iPhone / Mac 配套工程：将 iPhone 麦克风的声音通过局域网传给 Mac，让 Wispr Flow 等语音输入工具把它转成文字；同时提供切换应用和发送常用快捷键的手机遥控面板。

[English](README.md) | 简体中文

这是一个仍在开发中的独立项目。当前应用界面为中文，文档提供英文和中文版本。

## 已实现功能

- iPhone 按住说话，松开结束；界面显示手机麦克风音量。
- Mac 接收语音，并将音频输出到 BlackHole 2ch 或其他兼容的回环设备。
- 自动模拟按住并释放 Ctrl 或 Fn，触发使用对应快捷键的 Mac 语音工具；也可选择不发送触发键。
- 从手机打开 Codex，使用系统选择器发送 ⌘1–9 切换聊天，并发送常用键盘操作。
- iPhone 13 主界面采用单屏布局：底部并排放置按住说话和回车，常用按键直接可见；按键有震动、短提示和提示音。
- 使用 Bonjour 自动查找 Mac；连接设置直接显示设备名称，只有一台时自动连接，有多台时可选择，并保留手动输入 IP。
- 连接断开或手机返回前台时尝试重新连接；Mac 窗口显示连接、辅助功能权限、接收音量和本次接收时长。

已在当前设备上实测 iPhone → Mac → BlackHole 2ch → Wispr Flow 语音识别，以及应用切换和部分快捷键。其他系统版本、输入工具和所有异常恢复场景仍需要进一步测试。

## 阅读源码

每个主要方法都有中文注释；建议先看[中文代码导读](docs/CODE_GUIDE.zh-CN.md)，再按发现连接、语音和快捷键三条调用链阅读源码。

## 工作原理

```text
iPhone 麦克风 → 局域网 TCP → VoiceRemoteMac → BlackHole 2ch → Wispr Flow → Mac 当前输入框
                                      └── 模拟 Ctrl / Fn 和其他快捷键
```

手机端采集声音并转换为 16 kHz 单声道 PCM；Mac 接收端将它播放到选定的音频输出设备。BlackHole 这类回环设备把该输出提供为输入，让 Wispr Flow 等工具读取。

**本工程本身不做语音识别，也不在手机上显示识别结果。**识别文字由你选择的 Mac 语音工具生成，并按该工具的行为插入当前输入框。手机音量条表示采集到的音量；Mac 的接收音量和时长表示接收到的数据，均不能单独证明识别成功。

## 环境要求

- iPhone：iOS 27 或更高版本。
- Mac：macOS 14 或更高版本；构建需要 Xcode 及对应 iOS SDK。
- 两台设备可通过同一可信局域网互相访问；Mac 接收端监听 TCP `45971` 端口。
- 一个回环音频设备，例如 [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) 或已安装的 `MiRemoteV 2ch`。本工程不包含驱动。
- 一个 Mac 语音输入工具。以下以 Wispr Flow 为例；该工具需能够选择相应的回环设备。
- 将 iOS 调试版安装到真机时，需要 Xcode 中可用的 Apple 开发团队、签名证书和适用于设备的描述文件。

## 安装与首次运行

### 1. 准备回环音频设备

安装 BlackHole 2ch，或使用已经安装的兼容回环设备。安装后若 Mac 仍看不到设备，请按驱动安装说明处理，必要时保存工作并重启 Mac。

已安装 Homebrew 的用户也可以使用：

```bash
brew install --cask blackhole-2ch
```

安装系统音频驱动可能需要管理员授权。安装完成后，系统声音设置或 Mac 接收端的设备列表中应能看到 `BlackHole 2ch`。

### 2. 运行 Mac 接收端

1. 用 Xcode 打开 `Companion.xcodeproj`。
2. 选择 **VoiceRemoteMac** scheme，目标设备选择 **My Mac**，运行应用。
3. 在接收端窗口的“音频输出”中选择 **BlackHole 2ch**；没有出现时点击“刷新”。
4. “语音工具触发键”按目标工具设置：Wispr Flow 使用按住 Ctrl 时选择 **Ctrl（Wispr Flow）**；其他工具可以选择 **Fn / 地球键**或**不发送按键**。
5. 如果需要自动触发语音或使用手机快捷键，点击“请求辅助功能权限”，在系统设置中允许 VoiceRemoteMac 控制电脑。

在 macOS 27，相关设置页面可能显示为 **隐私与安全 → 设备控制和数据访问**。授权后返回应用，确认窗口显示“辅助功能权限：已授权”。如果系统开关已开启、应用仍显示未授权，可能是旧调试构建的签名记录不匹配：在该页面选中旧的 VoiceRemoteMac 条目并移除，再添加当前正在运行的 `VoiceRemoteMac.app`、开启开关，必要时重新启动接收端。重新构建或更换应用签名后也可能需要重新授权。

本机调试构建可位于 `Build/VoiceRemoteMac.app`；`Build/` 不纳入 Git，其他电脑应通过 Xcode 自行构建。没有辅助功能权限时仍可接收音频，但不能依赖自动触发键或遥控快捷键。

### 3. 运行 iPhone App

1. 在同一 Xcode 工程中选择 **VoiceRemotePhone** scheme。
2. 在 **Signing & Capabilities** 选择自己的开发团队；如有需要，将 Bundle Identifier 改为团队可用的唯一标识。
3. 连接并选择 iPhone，按 Xcode 和手机提示完成设备信任、开发者模式和签名配置，然后运行。
4. 首次使用时允许**局域网访问**与**麦克风**权限。

启动 Mac 接收端后，手机会通过 Bonjour 查找 Mac；首次需要在连接设置中输入配对码并选择设备，成功配对后会保存配对码。若发现多台 Mac，可在连接设置中选择。需要允许手机和 Mac 的局域网访问。部分热点或网络可能不转发 Bonjour；若找不到 Mac，打开连接设置，输入 Mac 接收端显示的 IP 和配对码，点击“连接”。手动填写的 IP 会保存在手机上。

首次启动时 Mac 会生成并保存六位配对码。请在手机“连接设置”中先输入 Mac 窗口显示的配对码，再选择发现的 Mac；手动连接时还需输入地址。手机会保存成功配对的配对码以供重连。此前旧版已实测普通 Wi-Fi 和 iPhone USB 热点；更新后的配对流程仍需在相应设备和网络上实测。

仓库不包含开发团队或签名文件。每位使用者都需要在 Xcode 中选择自己的开发团队，并将示例 Bundle Identifier 改成自己可用的唯一标识。

### 4. 配置 Wispr Flow 并测试

1. 打开 Wispr Flow，在麦克风设置中选择 **BlackHole 2ch**。如果列表默认隐藏虚拟设备，展开 **Show other devices** 后选择；选项位置可能随 Wispr Flow 版本变化。
2. 确认 Wispr Flow 的语音快捷键与 Mac 接收端一致。例如 Wispr Flow 设置为**按住 Ctrl 说话**时，接收端选择 **Ctrl（Wispr Flow）**。
3. 在 Mac 的目标应用中点击一个可编辑输入框，放好光标。
4. 在 iPhone 上确认显示“已连接”，按住“按住说话”并说一句话，再松开。
5. 观察手机音量条和 Mac 接收音量／接收时长，再检查目标输入框是否出现 Wispr Flow 识别的文字。

Wispr Flow 的账号、网络、语言及识别行为由该工具管理。若选择“不发送按键”，需要用目标工具自己的方式手动开始和结束语音输入。

## 遥控快捷键

手机端提供以下操作；按键发送给 Mac 当前前台应用，具体效果由目标应用决定。

| 手机按钮 | Mac 操作 |
| --- | --- |
| Codex | 尝试打开或激活已安装的 Codex |
| 切换应用 | Command + Tab |
| 上一项、下一项 | Shift + Tab、Tab |
| 聊天 1–9 | Command + 1–9，切换 Codex 聊天 |
| 删除 | Delete / Backspace，删除光标前一个字符 |
| 回车、换行、提交 | Return、Shift + Return、Command + Return |
| Esc、中断 | Escape、Control + C |
| Tab、上、下、左、右 | 对应的 Tab 和方向键 |
| 复制、粘贴、全选、撤销 | Command + C / V / A / Z |

普通快捷键会提供轻微震动、顶部短提示和系统提示音；语音键开始及结束时只震动，不播放提示音。提示只表示手机已发出操作，不代表目标应用一定执行成功。

例如 Command + Return 是否提交、Shift + Return 是否换行，取决于当前应用的快捷键配置。Codex 按钮通过代码中配置的应用标识查找应用；若找不到对应安装，不会打开其他应用。聊天选择器每次选中都会发送快捷键，不表示 Mac 当前实际选中的聊天。

## 常见问题

**手机显示未连接**

- 确认 Mac 接收端正在运行，手机与 Mac 位于可互通的同一局域网，并已允许局域网访问。
- 自动发现受网络组播限制；若一直找不到 Mac，可打开连接设置，手动填写 Mac 接收端窗口中的 IP。
- 对照 Mac 窗口检查手机里填写的 IP 和配对码；确认手机已允许局域网访问。
- 检查 Mac 防火墙或网络是否阻止 TCP `45971`，然后在手机上点击“连接”。
- 配对码错误后，Mac 会暂时拒绝新的连接；等待约 30 秒再试。
- 新连接通过配对后会接替之前的手机连接，避免旧连接残留阻止重连。若仍反复重试，可先手动输入 Mac 接收端显示的 IP，确认网络可达。

**手机提示麦克风启动失败，或音量条不动**

- 确认已在 iPhone 系统设置中允许该 App 使用麦克风，关闭可能占用麦克风的其他通话或录音应用后重试。
- 松开并重新按住说话键；如果仍失败，记录界面中显示的错误信息及错误代码，便于排查音频会话。
- App 不在前台时会结束当前录音；返回前台后重新连接、再按住说话。

**手机音量在动，但 Mac 接收音量和时长不变**

- 确认两端仍显示已连接，Mac 已选择有效的输出设备。
- 如手机提示 Mac 音频输出失败，点击 Mac 接收端的“刷新”，重新选择 BlackHole 2ch 后重试。

**Mac 接收音量在动，但没有文字**

- 确认 Wispr Flow 的麦克风选的是 BlackHole 2ch，而不是内置麦克风；必要时展开 **Show other devices**。
- 确认语音触发键与 Wispr Flow 设置一致、接收端显示辅助功能已授权，且光标位于目标输入框。
- 检查 Wispr Flow 自身是否正常工作，以及它的语言、账号和网络状态。

**检查接收日志**

Mac 接收端使用系统统一日志记录语音会话状态、接收帧数、归一化音量峰值和错误码，不记录音频或识别文本。可以在终端运行：

```bash
log show --last 30m --style compact --predicate 'subsystem == "com.example.voiceremote.mac" AND category == "voice"'
```

`voice_start` 表示开始接收；`voice_stop` 中的 `frames` 表示收到的 16 kHz 音频帧数，`peak` 是归一化的最大音量指标。它们能辅助判断接收过程，不能独立证明 Wispr Flow 已成功识别。

**系统开关已开启，接收端仍显示未授权**

检查是否授权了当前的 `VoiceRemoteMac.app`。若之前添加过未签名或其他路径下的测试版，移除旧条目并重新添加当前签名版，再重启接收端。授权会允许应用向 Mac 发送按键和控制其他应用。

## 构建与项目结构

```text
Companion.xcodeproj/   Xcode 工程：VoiceRemotePhone、VoiceRemoteMac
Phone/PhoneApp.swift   iPhone 界面、连接与麦克风采集
Mac/MacApp.swift       Mac 接收、回环音频与快捷键
Shared/Wire.swift      两端共用的 TCP 消息封装
```

可以在 Xcode 选择对应 scheme 构建。只检查 iOS 编译、无需签名安装时，也可以在工程目录运行：

```bash
xcodebuild -project Companion.xcodeproj -scheme VoiceRemotePhone \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

此命令只验证编译，**不能替代签名安装和真机测试**。Mac 接收端可选择 `VoiceRemoteMac` scheme 构建并运行。`.gitignore` 排除了 `Build/`、DerivedData 和 Xcode 用户状态。

## 当前安全与使用边界

详见 [安全说明](SECURITY.zh-CN.md)。

- 当前版本的 TCP 配对信息、音频和命令**未加密**，配对码不能防止局域网窃听。仅在可信局域网使用，不要映射到公网或在公共网络使用。
- 手机通过局域网向 Mac 发送音频，Mac 接收端输出到所选设备；语音工具可能根据其自身服务和设置处理或上传音频，请查看相应工具的隐私说明。
- 该 App 提供麦克风采集和遥控，不是系统级虚拟麦克风驱动；目标工具必须能读取所选回环设备。
- 当前项目是调试版本，设备兼容性、断线和权限变化等边界仍需继续验证。

## 许可证

本项目使用 [MIT License](LICENSE)。BlackHole 等独立安装的第三方软件遵循各自的许可证。
