// iPhone 端：负责设备发现、连接、麦克风采集和遥控界面。
// 两端的网络消息封装位于 Shared/Wire.swift；Mac 端不在此文件处理。
import SwiftUI
import AVFoundation
import Network
import UIKit
import AudioToolbox

/// Bonjour 浏览到的一条 Mac 服务记录。
/// id 用服务名称、类型、域和网卡区分记录；endpoint 用于后续连接。
struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// 手机端状态与业务逻辑：发现 Mac、建立连接、录音并发送遥控指令。
/// @MainActor 让界面观察的状态在主线程更新；网络和音频回调会切回主线程。
@MainActor final class PhoneModel: ObservableObject {
    // @Published 属性发生变化时，SwiftUI 会刷新依赖这些值的界面。
    @Published var host = UserDefaults.standard.string(forKey: "manualMacHost") ?? ""
    @Published var code = UserDefaults.standard.string(forKey: "pairingCode") ?? ""
    @Published var status = "未连接"
    @Published var connected = false
    @Published var recording = false
    @Published var microphoneLevel: Double = 0
    @Published var feedback = ""
    // 私有状态负责管理连接、录音任务与过期回调，不直接展示在界面上。
    private var feedbackTask: Task<Void, Never>?
    private var wire: Wire?
    private var engine: AVAudioEngine?
    private var captureGeneration = 0
    private var appActive = true
    @Published private(set) var discoveredMacs: [DiscoveredMac] = []
    private var browser: NWBrowser?
    private var automaticallyDiscover = true
    private var selectedMacName = UserDefaults.standard.string(forKey: "selectedMacName")
    private var attempt = UUID()

    /// 开始或复用 Bonjour 浏览，监听 _voiceremote._tcp 服务。
    /// 发现结果变化时更新列表，再根据已选设备或唯一设备尝试自动连接。
    func startDiscovery() {
        guard browser == nil else { connectDiscoveredIfAvailable(); return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_voiceremote._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = state {
                    self.browser = nil
                    if !self.connected { self.status = "自动查找失败，可手动输入地址" }
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
                let id = "\(name)|\(type)|\(domain)|\(interface?.name ?? "")"
                return DiscoveredMac(id: id, name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self else { return }
                self.discoveredMacs = devices
                self.connectDiscoveredIfAvailable()
            }
        }
        status = "正在查找 Mac…"
        browser.start(queue: .main)
    }

    /// 在前台、自动发现启用且没有现有连接时，选择合适的 Mac。
    /// 优先选择名称匹配的唯一记录；否则仅在列表只有一条时自动连接，多条交给用户选。
    private func connectDiscoveredIfAvailable() {
        guard automaticallyDiscover, appActive, !connected, wire == nil else { return }
        let matching = discoveredMacs.filter { $0.name == selectedMacName }
        let target = matching.count == 1 ? matching.first : (discoveredMacs.count == 1 ? discoveredMacs.first : nil)
        guard let target else {
            status = discoveredMacs.isEmpty ? "正在查找 Mac…" : "发现多台 Mac，请在连接设置中选择"
            return
        }
        connect(to: target.endpoint)
    }

    /// 连接用户选择的 Bonjour 服务，并记住设备名称以供下次自动匹配。
    /// - Parameter mac: 浏览得到的 Mac 记录，而不是手填的 IP 地址。
    func connectToDiscovered(_ mac: DiscoveredMac) {
        automaticallyDiscover = true
        selectedMacName = mac.name
        UserDefaults.standard.set(mac.name, forKey: "selectedMacName")
        connect(to: mac.endpoint)
    }

    /// 使用设置页输入的 IP 和配对码建立手动连接，并保存 IP。
    /// 手动模式下本次运行的断线重试继续使用这个地址。
    func connect() {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty, !code.isEmpty else { status = "请输入 Mac 地址和配对码"; return }
        automaticallyDiscover = false
        UserDefaults.standard.set(host, forKey: "manualMacHost")
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: 45971))
    }

    /// 按指定服务或 IP 创建 TCP 连接，握手后等待 Mac 的 ready 消息。
    /// - Parameter endpoint: Bonjour 服务端点或带 45971 端口的主机地址。
    /// 连接失败后延迟三秒重试；八秒未握手成功则取消，旧回调由 attempt 和对象身份过滤。
    private func connect(to endpoint: NWEndpoint) {
        guard !code.isEmpty else { status = "请输入配对码"; return }
        stopVoice()
        connected = false
        wire?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let c = NWConnection(to: endpoint, using: parameters)
        let w = Wire(c); wire = w
        let currentAttempt = UUID(); attempt = currentAttempt
        status = "连接中…"
        w.onState = { [weak self, weak w] state in
            Task { @MainActor in
                guard let self, self.wire === w else { return }
                switch state {
                case .ready: w?.send(Message(type: "auth", value: self.code))
                case .failed, .cancelled:
                    self.stopVoice(); self.connected = false; self.wire = nil
                    self.status = "连接断开，正在重试…"
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, self.attempt == currentAttempt, self.wire == nil, self.appActive, !self.connected else { return }
                        if self.automaticallyDiscover { self.connectDiscoveredIfAvailable() } else { self.connect() }
                    }
                default: break
                }
            }
        }
        w.onMessage = { [weak self, weak w] message in
            Task { @MainActor in
                guard let self, self.wire === w else { return }
                if message.type == "ready" { self.connected = true; self.status = "已连接"; UserDefaults.standard.set(self.code, forKey: "pairingCode") }
                if message.type == "error" { self.stopVoice(); self.status = message.value ?? "连接失败" }
            }
        }
        w.start()
        Task { @MainActor [weak self, weak w] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, let w, self.attempt == currentAttempt, self.wire === w, !self.connected else { return }
            w.cancel()
        }
    }
    /// 根据 App 前后台状态停止录音或尝试恢复连接。
    /// - Parameter active: App 是否处于活动前台；后台不会继续当前录音。
    func setActive(_ active: Bool) {
        appActive = active
        if !active { stopVoice() }
        else if !connected {
            if automaticallyDiscover { startDiscovery() } else { connect() }
        }
    }
    /// 向 Mac 发送一个遥控命令，并在手机端播放触感、提示音和短暂文字反馈。
    /// - Parameter name: 双方约定的命令标识，例如 return、copy 或 chat_1。
    /// 本地反馈只代表命令已发出，不代表 Mac 前台应用一定执行成功。
    func command(_ name: String) {
        guard connected else { return }
        wire?.send(Message(type: "command", value: name))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !recording { AudioServicesPlaySystemSound(1104) }
        let labels = ["backspace": "删除", "tab": "下一项", "shift_tab": "上一项",
                      "return": "回车", "escape": "Esc", "shift_return": "换行", "command_return": "提交",
                      "copy": "复制", "paste": "粘贴", "undo": "撤销", "control_c": "中断",
                      "select_all": "全选", "switch": "切换应用", "codex": "Codex", "cursor": "Cursor",
                      "left": "向左", "up": "向上", "down": "向下", "right": "向右"]
        feedback = name.hasPrefix("chat_") ? "聊天 " + name.dropFirst(5) : (labels[name] ?? "已按下")
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            feedback = ""
        }
    }
    /// 按住语音键时请求麦克风权限，许可后启动录音。
    /// 用 captureGeneration 排除权限弹窗期间已松手、断线或重新开始造成的过期回调。
    func startVoice() {
        guard connected, !recording else { return }
        captureGeneration += 1
        let requestGeneration = captureGeneration
        recording = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.connected, self.recording, self.captureGeneration == requestGeneration else { return }
                guard granted else { self.recording = false; self.status = "请在系统设置中允许麦克风权限"; return }
                do { try self.beginCapture() } catch { self.recording = false; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); let nsError = error as NSError; self.status = "麦克风启动失败：\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]" }
            }
        }
    }
    /// 配置音频会话和采集引擎，把麦克风采样转换为 16 kHz、单声道、16 位 PCM。
    /// 先发送 voice_start，再逐块计算音量并以 Base64 的 audio 消息发送；失败时抛出错误。
    private func beginCapture() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            // 某些音频路由拒绝纯录音会话；改用可混音的播放并录音模式重试。
            // 两次都失败时保留首次错误信息，方便定位音频会话问题。
            let firstError = error as NSError
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
            } catch {
                let secondError = error as NSError
                throw NSError(domain: secondError.domain, code: secondError.code, userInfo: [NSLocalizedDescriptionKey: "\(secondError.localizedDescription)；首次尝试 \(firstError.domain) \(firstError.code)"])
            }
        }
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: output) else { throw NSError(domain: "audio", code: 1) }
        let w = wire
        let levelGeneration = captureGeneration
        w?.send(Message(type: "voice_start"))
        // 音频回调按块执行：转换采样格式、计算均方根音量，再编码发送。
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            let size = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: size) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return }
            let count = Int(converted.frameLength)
            var energy: Double = 0
            for i in 0..<count { let sample = Double(samples[0][i]); energy += sample * sample }
            let level = min(1.0, sqrt(energy / Double(count)) / 5000.0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recording, self.captureGeneration == levelGeneration else { return }
                self.microphoneLevel = level
            }
            let data = Data(bytes: samples[0], count: count * 2)
            w?.send(Message(type: "audio", value: data.base64EncodedString()))
        }
        do { try audioEngine.start(); engine = audioEngine }
        catch { input.removeTap(onBus: 0); w?.send(Message(type: "voice_stop")); throw error }
    }
    /// 松开语音键或退出前台时停止采集、清空音量、通知 Mac 并释放音频会话。
    /// 递增 captureGeneration 可防止旧音量或权限回调覆盖当前状态。
    func stopVoice() {
        guard recording else { return }
        recording = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        microphoneLevel = 0
        captureGeneration += 1
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil; wire?.send(Message(type: "voice_stop")) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 手机遥控器使用的背景、按钮、强调色和次要文字颜色。
private enum RemoteTheme {
    static let background = Color(red: 0.055, green: 0.066, blue: 0.085)
    static let surface = Color(red: 0.12, green: 0.14, blue: 0.17)
    static let accent = Color(red: 0.67, green: 0.91, blue: 0.80)
    static let secondary = Color(red: 0.67, green: 0.71, blue: 0.74)
}

/// 普通遥控按钮的按下反馈样式，不改变按钮尺寸。
private struct RemoteKeyStyle: ButtonStyle {
    /// 根据按钮是否按下调整透明度，并使用短动画显示反馈。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 可复用的遥控按钮：包含主标题、可选快捷键说明和点击动作。
private struct RemoteKey: View {
    let title: String
    var subtitle: String = ""
    var prominent = false
    var height: CGFloat = 52
    let action: () -> Void
    /// 组合标题、可选副标题、背景和点击反馈，供主界面重复使用。
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 10, weight: .medium)).opacity(0.72).lineLimit(1) }
            }
            .foregroundStyle(prominent ? RemoteTheme.background : Color.white)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(prominent ? RemoteTheme.accent : RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }.buttonStyle(RemoteKeyStyle()).accessibilityLabel(subtitle.isEmpty ? title : "\(title)，\(subtitle)")
    }
}

/// 连接设置页：显示发现的 Mac，也允许填写 IP 和配对码手动连接。
private struct ConnectionSettings: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    /// 构建发现列表、手动地址、配对码和连接按钮。
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Mac 连接").font(.headline)
                SecureField("配对码（见 Mac 窗口）", text: $model.code).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                if !model.discoveredMacs.isEmpty {
                    Text("发现的 Mac").font(.headline)
                    if model.discoveredMacs.count == 1, let mac = model.discoveredMacs.first {
                        Button(mac.name) { model.connectToDiscovered(mac); if !model.code.isEmpty { dismiss() } }
                            .buttonStyle(.bordered)
                    } else {
                        Menu {
                            ForEach(model.discoveredMacs) { mac in
                                Button(mac.name) { model.connectToDiscovered(mac); if !model.code.isEmpty { dismiss() } }
                            }
                        } label: {
                            HStack {
                                Text(model.discoveredMacs.map(\.name).joined(separator: "、")).lineLimit(2)
                                Image(systemName: "chevron.down")
                            }
                        }.buttonStyle(.bordered)
                    }
                } else {
                    Text("正在查找附近的 Mac…").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("手动连接").font(.headline)
                TextField("Mac 局域网 IP 地址", text: $model.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                Button("连接") { model.connect(); if !model.code.isEmpty && !model.host.trimmingCharacters(in: .whitespaces).isEmpty { dismiss() } }.buttonStyle(.borderedProminent)
                Text("手机和 Mac 需要连接到同一个可信局域网。")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(24).navigationTitle("连接设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// iPhone 遥控主界面：保持单屏，并把语音与回车放在底部。
private struct RemoteView: View {
    @ObservedObject var model: PhoneModel
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    /// 根据可用高度布局单屏按键，并监听应用前后台状态。
    var body: some View {
        GeometryReader { geometry in
            // 为顶部状态栏、间距和底部拇指操作区预留高度，再计算各行按钮高度。
            let availableHeight: CGFloat = geometry.size.height - 220
            let keyHeight: CGFloat = min(max(availableHeight / 6, 52), 78)
            VStack(spacing: 12) {
                header
                chatPicker(height: keyHeight)
                HStack(spacing: 8) {
                    RemoteKey(title: "上一项", subtitle: "⇧ Tab", height: keyHeight) { model.command("shift_tab") }
                    RemoteKey(title: "下一项", subtitle: "Tab", height: keyHeight) { model.command("tab") }
                    RemoteKey(title: "Esc", height: keyHeight) { model.command("escape") }
                }.disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                HStack(spacing: 8) {
                    RemoteKey(title: "删除", subtitle: "⌫", height: keyHeight) { model.command("backspace") }
                    RemoteKey(title: "换行", subtitle: "⇧ ↩", height: keyHeight) { model.command("shift_return") }
                    RemoteKey(title: "提交", subtitle: "⌘ ↩", height: keyHeight) { model.command("command_return") }
                }.disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                HStack(spacing: 8) {
                    RemoteKey(title: "←", height: keyHeight) { model.command("left") }.accessibilityLabel("向左")
                    RemoteKey(title: "↑", height: keyHeight) { model.command("up") }.accessibilityLabel("向上")
                    RemoteKey(title: "↓", height: keyHeight) { model.command("down") }.accessibilityLabel("向下")
                    RemoteKey(title: "→", height: keyHeight) { model.command("right") }.accessibilityLabel("向右")
                }.disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                HStack(spacing: 8) {
                    RemoteKey(title: "Codex", height: keyHeight) { model.command("codex") }
                    RemoteKey(title: "切换应用", subtitle: "⌘ Tab", height: keyHeight) { model.command("switch") }
                    RemoteKey(title: "中断", subtitle: "⌃ C", height: keyHeight) { model.command("control_c") }
                }.disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                HStack(spacing: 8) {
                    RemoteKey(title: "复制", subtitle: "⌘ C", height: keyHeight) { model.command("copy") }
                    RemoteKey(title: "粘贴", subtitle: "⌘ V", height: keyHeight) { model.command("paste") }
                    RemoteKey(title: "全选", subtitle: "⌘ A", height: keyHeight) { model.command("select_all") }
                    RemoteKey(title: "撤销", subtitle: "⌘ Z", height: keyHeight) { model.command("undo") }
                }.disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    voiceControl
                    RemoteKey(title: "回车", subtitle: "Return", prominent: true, height: 76) { model.command("return") }
                        .frame(width: 104)
                        .disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(RemoteTheme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .sheet(isPresented: $showingSettings) { ConnectionSettings(model: model) }
        .onAppear { if !model.connected { model.startDiscovery() } }
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
    }

    /// 创建系统菜单式聊天选择器，选择 1–9 后发送对应的 Command 数字键。
    /// - Parameter height: 与其他遥控按键保持一致的高度。
    /// 绑定始终读取占位值 0，因此同一数字可以重复发送；不代表 Mac 当前实际聊天。
    private func chatPicker(height: CGFloat) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("切换聊天").font(.system(size: 15, weight: .semibold))
                Text("⌘ 1–9").font(.system(size: 11, weight: .medium)).foregroundStyle(RemoteTheme.secondary)
            }
            Spacer(minLength: 8)
            Picker("切换聊天", selection: Binding(
                get: { 0 },
                set: { number in if number > 0 { model.command("chat_\(number)") } }
            )) {
                Text("选择聊天").tag(0)
                ForEach(1...9, id: \.self) { number in
                    Text("聊天 \(number)").tag(number)
                }
            }
            .pickerStyle(.menu)
            .tint(RemoteTheme.accent)
            .accessibilityHint("选择后发送对应的 Command 数字快捷键。")
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: height)
        .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .disabled(!model.connected).opacity(model.connected ? 1 : 0.5)
    }

    /// 显示连接状态、最近的操作反馈和连接设置入口。
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("遥控 Codex").font(.system(size: 20, weight: .bold))
                HStack(spacing: 6) {
                    Circle().fill(model.connected ? RemoteTheme.accent : Color.orange).frame(width: 7, height: 7)
                    Text(model.feedback.isEmpty ? (model.connected ? "Mac 已连接" : model.status) : model.feedback)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(RemoteTheme.secondary)
                }
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(RemoteTheme.surface, in: Circle())
            }.accessibilityLabel("连接设置")
        }
    }

    /// 显示麦克风音量并处理按住开始、松开结束的语音手势。
    /// 同时提供无障碍动作，避免只能通过触摸手势操作。
    private var voiceControl: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: model.recording ? "waveform" : "mic.fill")
                Text(model.recording ? "正在说话 · 松开结束" : "按住说话").fontWeight(.semibold)
            }.font(.system(size: 17)).lineLimit(1).minimumScaleFactor(0.7)
            ProgressView(value: model.microphoneLevel).tint(RemoteTheme.background.opacity(0.7)).padding(.horizontal, 16)
        }
        .foregroundStyle(RemoteTheme.background)
        .frame(maxWidth: .infinity).frame(height: 76)
        .background(model.recording ? Color.white : RemoteTheme.accent, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.startVoice() }.onEnded { _ in model.stopVoice() })
        .accessibilityElement(children: .ignore).accessibilityLabel("语音输入")
        .accessibilityHint("按住说话，松开结束。")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "开始说话") { model.startVoice() }
        .accessibilityAction(named: "结束说话") { model.stopVoice() }
        .opacity(model.connected ? 1 : 0.5).allowsHitTesting(model.connected)
    }
}

/// iOS 应用入口：创建并持有 PhoneModel，将它传给遥控主界面。
@main struct PhoneApp: App {
    @StateObject private var model = PhoneModel()
    /// 创建窗口并注入整个应用共用的手机状态模型。
    var body: some Scene { WindowGroup { RemoteView(model: model) } }
}
