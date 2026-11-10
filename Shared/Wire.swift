// 手机和 Mac 共用的通信层：统一消息结构、编码和 TCP 数据分帧。
import Foundation
import Network

/// 两端通用的 JSON 消息。type 表示消息种类，value 存放配对码、命令或 Base64 音频等可选内容。
struct Message: Codable {
    var type: String
    var value: String? = nil
}

/// 对一条 TCP 连接的轻量封装：每行是一条 JSON 消息，并限制未处理数据大小。
/// TCP 不保留消息边界，因此 receive 会缓存半包并按换行拆分。
final class Wire {
    let connection: NWConnection
    // 连接状态和接收回调在此串行队列执行，便于按顺序处理接收缓存。
    private let queue = DispatchQueue(label: "companion.wire")
    private var pending = Data()
    // 回调在连接队列执行；需要修改界面状态时，由调用方切换到主线程。
    var onMessage: ((Message) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    /// 保存已有的 Network 框架连接；连接可由手机主动创建或由 Mac 监听器接受。
    init(_ connection: NWConnection) { self.connection = connection }
    /// 注册连接状态回调、启动连接，并开始持续读取数据。
    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.onState?(state) }
        connection.start(queue: queue)
        receive()
    }
    /// 把消息编码为 JSON，在末尾加换行后异步发送。
    /// - Parameter message: 要发送的业务消息；编码失败时直接忽略。
    func send(_ message: Message) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    /// 取消底层 TCP 连接；状态变化通过 onState 回调通知使用方。
    func cancel() { connection.cancel() }
    /// 持续读取字节、缓存未完成的数据，并按换行拆分和解码 JSON。
    /// 缓存超过 256 KiB、收到结束标志或发生读取错误时取消连接。
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.pending.append(data) }
            if self.pending.count > 262144 { self.cancel(); return }
            // 10 是换行符：一块 TCP 数据可能包含半条、一条或多条消息。
            while let end = self.pending.firstIndex(of: 10) {
                let frame = self.pending.prefix(upTo: end)
                if let message = try? JSONDecoder().decode(Message.self, from: frame) { self.onMessage?(message) }
                self.pending.removeSubrange(...end)
            }
            if complete || error != nil { self.cancel(); return }
            self.receive()
        }
    }
}
