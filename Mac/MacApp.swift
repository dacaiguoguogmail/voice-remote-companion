// Mac 端：接收手机语音并输出到虚拟音频设备，同时执行遥控快捷键。
// 传输消息的格式及收发封装位于 Shared/Wire.swift。
import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import Network
import AppKit
import ApplicationServices
import Darwin
import IOKit.hidsystem
import OSLog

/// 可选音频输出设备：id 是 CoreAudio 设备编号，name 是界面显示的名称。
struct AudioDevice: Identifiable, Hashable { let id: AudioDeviceID; let name: String }

/// Mac 接收端的业务状态：管理发现广播、手机配对、音频输出及键盘模拟。
/// 界面状态和连接归属在主线程维护；网络回调通过 Task 切回主线程。
@MainActor final class MacModel: ObservableObject {
    // 供 SwiftUI 展示的状态；地址、设备和权限可能随系统环境变化。
    @Published var status = "等待连接"
    @Published var code = UserDefaults.standard.string(forKey: "pairingCode") ?? String(format: "%06d", Int.random(in: 0...999999))
    @Published var devices: [AudioDevice] = []
    @Published var selectedDevice: AudioDeviceID = 0
    @Published var voiceShortcut = "control"
    @Published var addresses = ""
    @Published var receivedLevel: Double = 0
    @Published var audioFrames = 0
    @Published var accessibilityReady = AXIsProcessTrusted()
    // 连接、认证及语音会话的内部状态；一次只允许一条已配对连接。
    private var listener: NWListener?
    private var wire: Wire?
    private var pendingWires: [ObjectIdentifier: Wire] = [:]
    private var authorized = false
    private var rejectUntil = Date.distantPast
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var voiceActive = false
    private var heldShortcut: String?
    private var generation = 0
    private var sessionPeak: Double = 0
    private let logger = Logger(subsystem: "com.example.voiceremote.mac", category: "voice")
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// 初始化时加载音频设备和本机地址，并启动 TCP/Bonjour 服务。
    init() { UserDefaults.standard.set(code, forKey: "pairingCode"); refreshDevices(); refreshAddresses(); start() }
    /// 遍历本机网络接口，收集非回环 IPv4 地址，用于界面展示和手动连接。
    /// 可能同时有多个地址；应选择与手机互通的接口地址。
    func refreshAddresses() {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return }
        defer { freeifaddrs(first) }
        var found: [String] = []
        var item = first
        while let entry = item {
            defer { item = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { found.append(String(cString: host)) }
        }
        addresses = found.joined(separator: "、")
    }
    /// 通过 CoreAudio 枚举带输出流的设备并读取名称。
    /// 原选择失效时优先选择名称含 MiRemoteV 或 BlackHole 的设备。
    func refreshDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        devices = ids.compactMap { id in
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            return AudioDevice(id: id, name: name as String)
        }
        if !devices.contains(where: { $0.id == selectedDevice }) { selectedDevice = devices.first(where: { $0.name.contains("MiRemoteV") || $0.name.contains("BlackHole") })?.id ?? 0 }
    }
    /// 监听 TCP 45971 端口，同时发布 Bonjour 服务供手机自动发现。
    /// 监听或广播状态发生变化时更新界面或写系统日志。
    private func start() {
        do {
            let listener = try NWListener(using: .tcp, on: 45971)
            self.listener = listener
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_voiceremote._tcp")
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor in self?.logger.info("bonjour_registration \(String(describing: change), privacy: .public)") }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.stateUpdateHandler = { [weak self] state in if case .failed(let error) = state { Task { @MainActor in self?.status = "监听失败：\(error.localizedDescription)" } } }
            listener.start(queue: .global(qos: .userInitiated))
        } catch { status = "监听失败：\(error.localizedDescription)" }
    }
    /// 接收新 TCP 连接并放入待配对列表。
    /// - Parameter connection: Network 框架交来的连接；未完成配对时不能替换当前手机。
    /// 最多保留四条待配对连接，十秒未完成配对会取消。
    private func accept(_ connection: NWConnection) {
        // 未完成配对的连接不能挤掉当前手机；单独限制待配对连接数量。
        guard pendingWires.count < 4, Date() >= rejectUntil else { connection.cancel(); return }
        let w = Wire(connection)
        let id = ObjectIdentifier(w)
        pendingWires[id] = w
        w.onState = { [weak self, weak w] state in
            if case .failed = state { Task { @MainActor in self?.disconnected(w) } }
            if case .cancelled = state { Task { @MainActor in self?.disconnected(w) } }
        }
        w.onMessage = { [weak self, weak w] message in Task { @MainActor in self?.handle(message, from: w) } }
        w.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak w] in
            guard let self, let w, self.pendingWires[ObjectIdentifier(w)] === w else { return }
            w.cancel()
        }
    }
    /// 清除断开的待配对连接；如果它是当前手机，还要立即停止语音并释放按键。
    /// - Parameter w: 发生断开的连接；旧连接的回调不能清掉新的连接。
    private func disconnected(_ w: Wire?) {
        guard let w else { return }
        pendingWires.removeValue(forKey: ObjectIdentifier(w))
        guard wire === w else { return }
        stopVoice(immediate: true); wire = nil; authorized = false; status = "等待连接"
        logger.info("connection_disconnected")
    }
    /// 处理手机消息：先验证待配对连接，再分发语音和快捷键命令。
    /// - Parameters:
    ///   - message: 解码后的消息，type 决定处理方式。
    ///   - w: 消息来源；只有成功配对的当前连接能控制 Mac。
    /// 成功配对的新连接会接替旧连接；错误配对码会暂时拒绝新的连接。
    private func handle(_ message: Message, from w: Wire?) {
        guard let w else { return }
        if wire !== w {
            guard pendingWires[ObjectIdentifier(w)] === w else { return }
            guard message.type == "auth", message.value == code else {
                rejectUntil = Date().addingTimeInterval(30)
                pendingWires.removeValue(forKey: ObjectIdentifier(w))
                w.cancel(); status = "配对失败，请在 30 秒后重试"
                logger.warning("connection_auth_failed")
                return
            }
            pendingWires.removeValue(forKey: ObjectIdentifier(w))
            if let old = wire {
                stopVoice(immediate: true)
                wire = nil
                old.cancel()
                logger.info("connection_replaced_stale_or_previous")
            }
            wire = w; authorized = true; status = "手机已连接"
            logger.info("connection_authenticated")
            w.send(Message(type: "ready")); return
        }
        guard authorized else { return }
        switch message.type {
        case "voice_start": startVoice()
        case "audio": if voiceActive, let value = message.value, let data = Data(base64Encoded: value) { play(data) }
        case "voice_stop": stopVoice(immediate: false)
        case "command": if let value = message.value { command(value) }
        default: break
        }
    }
    /// 为一次语音会话创建播放引擎，选择输出设备，并按配置按下 Ctrl 或 Fn。
    /// 没有辅助功能权限时仍尝试输出音频，但无法依赖模拟触发键。
    private func startVoice() {
        guard !voiceActive, selectedDevice != 0 else { status = "请先选择虚拟音频设备"; wire?.send(Message(type: "error", value: status)); return }
        accessibilityReady = AXIsProcessTrusted()
        audioFrames = 0; receivedLevel = 0; sessionPeak = 0
        logger.notice("voice_start accessibility=\(self.accessibilityReady, privacy: .public) trigger=\(self.voiceShortcut, privacy: .public)")
        generation += 1
        if let heldShortcut { shortcut(heldShortcut, down: false); self.heldShortcut = nil }
        player?.stop(); audioEngine?.stop(); player = nil; audioEngine = nil
        do {
            let engine = AVAudioEngine(); let node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
            guard let unit = engine.outputNode.audioUnit else { throw NSError(domain: "audio", code: 1) }
            var id = selectedDevice
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
            try engine.start(); node.play(); audioEngine = engine; player = node
            voiceActive = true
            if voiceShortcut != "none" && accessibilityReady {
                shortcut(voiceShortcut, down: true); heldShortcut = voiceShortcut
            }
            status = voiceShortcut != "none" && !accessibilityReady
                ? "正在接收语音；请检查辅助功能权限"
                : "正在接收语音"
        } catch {
            let nsError = error as NSError
            logger.error("output_failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            status = "音频输出失败：\(error.localizedDescription)"; wire?.send(Message(type: "error", value: status))
        }
    }
    /// 校验并播放一块手机发来的 16 位 PCM，同时更新接收帧数、音量和峰值。
    /// - Parameter data: Base64 解码后的原始音频字节；数据必须为偶数长度。
    private func play(_ data: Data) {
        guard data.count > 0, data.count <= 65536, data.count % 2 == 0, let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)), let target = buffer.int16ChannelData else { return }
        var energy: Double = 0
        // 两个小端字节还原成一个有符号采样值，用均方根估算音量。
        data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: values.count, by: 2) {
                let bits = UInt16(values[i]) | (UInt16(values[i + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits))
                energy += sample * sample
            }
        }
        audioFrames += Int(buffer.frameCapacity)
        receivedLevel = min(1.0, sqrt(energy / Double(buffer.frameCapacity)) / 5000.0)
        sessionPeak = max(sessionPeak, receivedLevel)
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { if let base = $0.baseAddress { memcpy(target[0], base, data.count) } }
        player.scheduleBuffer(buffer)
    }
    /// 结束当前语音会话，释放模拟按键并停止音频引擎。
    /// - Parameter immediate: true 立即清理；false 等已排队音频播放完后清理，最多等待三秒。
    /// generation 防止上一次会话的延迟回调误关新会话。
    private func stopVoice(immediate: Bool) {
        guard voiceActive || (immediate && (heldShortcut != nil || audioEngine != nil)) else { return }
        voiceActive = false
        logger.notice("voice_stop frames=\(self.audioFrames, privacy: .public) peak=\(self.sessionPeak, privacy: .public) immediate=\(immediate, privacy: .public)")
        let current = generation
        let finish: () -> Void = { [weak self] in
            guard let self, self.generation == current else { return }
            self.generation += 1
            if let held = self.heldShortcut { self.shortcut(held, down: false); self.heldShortcut = nil }
            self.player?.stop(); self.audioEngine?.stop(); self.player = nil; self.audioEngine = nil
            self.status = self.authorized ? "手机已连接" : "等待连接"
        }
        if immediate { finish(); return }
        guard let player, let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { finish(); return }
        end.frameLength = 1; end.int16ChannelData?[0][0] = 0
        player.scheduleBuffer(end, completionCallbackType: .dataPlayedBack) { _ in Task { @MainActor in finish() } }
        // 万一播放完成回调丢失，三秒后仍会释放模拟按键，避免按键一直被按住。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
    }
    /// 使用 CGEvent 模拟 Ctrl 或 Fn 的按下与松开，触发 Mac 语音输入工具。
    /// - Parameters:
    ///   - shortcut: control 表示 Ctrl，其余调用路径使用 Fn。
    ///   - down: true 按下，false 松开；发送成功依赖辅助功能权限。
    private func shortcut(_ shortcut: String, down: Bool) {
        let code: CGKeyCode = shortcut == "control" ? 59 : 63
        let modifier: CGEventFlags = shortcut == "control"
            ? CGEventFlags.maskControl.union(CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK)))
            : .maskSecondaryFn
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = down ? modifier : []; event.post(tap: .cghidEventTap)
    }
    /// 将手机命令映射成 Mac 操作：切换聊天、打开应用或发送组合键。
    /// - Parameter name: 例如 chat_1、codex、return；未知命令直接忽略。
    /// 模拟的按键发送到当前前台应用，具体行为取决于该应用的快捷键设置。
    private func command(_ name: String) {
        let chatKeys: [String: CGKeyCode] = ["chat_1": 18, "chat_2": 19, "chat_3": 20,
            "chat_4": 21, "chat_5": 23, "chat_6": 22, "chat_7": 26, "chat_8": 28, "chat_9": 25]
        if let key = chatKeys[name] {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            return
        }
        let launch: [String: String] = ["codex": "com.openai.codex", "cursor": "com.todesktop.230313mzl4w4u92"]
        if let bundleID = launch[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return
        }
        let keys: [String: (CGKeyCode, CGEventFlags)] = ["switch": (48, .maskCommand), "return": (36, []), "backspace": (51, []), "escape": (53, []), "copy": (8, .maskCommand), "paste": (9, .maskCommand), "undo": (6, .maskCommand), "shift_return": (36, .maskShift), "command_return": (36, .maskCommand), "control_c": (8, .maskControl), "tab": (48, []), "shift_tab": (48, .maskShift), "up": (126, []), "down": (125, []), "left": (123, []), "right": (124, []), "select_all": (0, .maskCommand)]
        guard let (key, flags) = keys[name] else { return }
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
    }
}

/// macOS 应用入口：创建接收模型并展示连接、音频设备和权限设置窗口。
@main struct MacApp: App {
    @StateObject private var model = MacModel()
    /// 创建设置窗口，展示连接、接收音量、设备与辅助功能权限。
    var body: some Scene {
        WindowGroup {
            Form {
                Text("手机和 Mac 连接同一局域网。在 iPhone 输入 Mac 的局域网 IP 和下面的配对码。")
                LabeledContent("Mac 地址", value: model.addresses.isEmpty ? "未找到网络地址" : model.addresses).textSelection(.enabled)
                LabeledContent("配对码", value: model.code).textSelection(.enabled)
                LabeledContent("连接状态", value: model.status)
                LabeledContent("辅助功能权限", value: model.accessibilityReady ? "已授权" : "未授权")
                ProgressView("Mac 接收音量", value: model.receivedLevel)
                LabeledContent("本次接收", value: String(format: "%.1f 秒", Double(model.audioFrames) / 16000))
                HStack {
                    Picker("音频输出", selection: $model.selectedDevice) {
                        Text("请选择虚拟音频设备").tag(AudioDeviceID(0))
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                    }
                    Button("刷新") { model.refreshDevices() }
                }
                Picker("语音工具触发键", selection: $model.voiceShortcut) {
                    Text("Ctrl（Wispr Flow）").tag("control")
                    Text("Fn / 地球键").tag("fn")
                    Text("不发送按键").tag("none")
                }
                Text("语音工具中选择相同的虚拟音频设备。快捷键和语音触发键需要在系统设置中授予辅助功能权限。连接与音频在局域网传输，当前版本未加密，请仅在可信网络使用。")
                    .foregroundStyle(.secondary)
                Button("请求辅助功能权限") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    model.accessibilityReady = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.accessibilityReady = AXIsProcessTrusted()
            }.padding().frame(minWidth: 520, minHeight: 390)
        }.windowResizability(.contentMinSize)
    }
}
