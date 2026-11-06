import Foundation
import Dispatch
import NIOCore
import NIOPosix

private enum NetworkRuntime {
    // Shared across listeners and guest virtual-serial connections for the process.
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// Ordered byte-stream connection. Public operations and callbacks use the main
/// queue; socket readiness and buffering are handled by SwiftNIO's event loop.
public final class TCPConnection: @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onReceive: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?
    public private(set) var remoteAddress: String
    private var channel: Channel?
    private let endpoint: (String, UInt16)?
    private var started = false
    private var closed = false

    public init(host: String, port: UInt16) {
        endpoint = (host, port)
        remoteAddress = host
    }

    fileprivate init(channel: Channel) {
        self.channel = channel
        endpoint = nil
        remoteAddress = channel.remoteAddress?.ipAddress ?? "unknown"
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        if let channel {
            activate(channel)
        } else if let (host, port) = endpoint {
            ClientBootstrap(group: NetworkRuntime.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .connect(host: host, port: Int(port)).whenComplete { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let channel): self.activate(channel)
                        case .failure(let error): self.finish(error)
                        }
                    }
                }
        }
    }

    private func activate(_ channel: Channel) {
        guard !closed else { channel.close(promise: nil); return }
        self.channel = channel
        channel.pipeline.addHandler(BytesHandler(owner: self)).whenComplete { result in
            DispatchQueue.main.async {
                guard !self.closed else { channel.close(promise: nil); return }
                switch result {
                case .success:
                    self.onReady?()
                    channel.eventLoop.execute {
                        // Check and enable reads on the same event loop so a
                        // close cannot deregister the socket between them.
                        guard channel.isActive else { return }
                        channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { error in
                            DispatchQueue.main.async { self.finish(error) }
                        }
                    }
                case .failure(let error): self.finish(error)
                }
            }
        }
    }

    public func send(_ data: Data) {
        guard !closed, let channel, !data.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer).whenFailure { error in
            DispatchQueue.main.async { self.finish(error) }
        }
    }

    public func cancel() { finish(nil) }

    fileprivate func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        channel?.close(promise: nil)
        channel = nil
        onClose?(error)
    }

    private final class BytesHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private weak var owner: TCPConnection?
        init(owner: TCPConnection) { self.owner = owner }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            DispatchQueue.main.async { [weak owner] in
                guard let owner, !owner.closed else { return }
                owner.onReceive?(bytes)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            DispatchQueue.main.async { [weak owner] in owner?.finish(nil) }
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            DispatchQueue.main.async { [weak owner] in owner?.finish(error) }
            context.close(promise: nil)
        }
    }
}

/// TCP listener with synchronous bind errors. Accepted connections do not read
/// until start(), allowing virtual-serial clients to join a pending connection.
public final class TCPListener: @unchecked Sendable {
    private var channel: Channel?
    private var generation = 0
    public private(set) var port: UInt16
    private let address: String

    public init(host: String = "127.0.0.1", port: UInt16) {
        address = host
        self.port = port
    }

    public func start(onAccept: @escaping (TCPConnection) -> Void) throws {
        guard channel == nil else { return }
        generation += 1
        let token = generation
        #if os(Windows)
        // WinSock SO_EXCLUSIVEADDRUSE is defined as ~SO_REUSEADDR.
        // SO_REUSEADDR on Windows permits competing listeners on one port.
        let bindOption = NIOBSDSocket.Option(rawValue: ~NIOBSDSocket.Option.so_reuseaddr.rawValue)
        #else
        let bindOption = NIOBSDSocket.Option.so_reuseaddr
        #endif
        channel = try ServerBootstrap(group: NetworkRuntime.group)
            .serverChannelOption(ChannelOptions.socketOption(bindOption), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                let connection = TCPConnection(channel: channel)
                DispatchQueue.main.async {
                    guard self.generation == token, self.channel != nil else { connection.cancel(); return }
                    onAccept(connection)
                }
                return channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: address, port: Int(port)).wait()
        port = UInt16(channel!.localAddress!.port!)
    }

    public func cancel() {
        // Called from the main queue, never from the NIO event loop.
        generation += 1
        try? channel?.close().wait()
        channel = nil
    }
}
