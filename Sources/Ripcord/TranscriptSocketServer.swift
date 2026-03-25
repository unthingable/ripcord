import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "TranscriptSocket")

/// Broadcasts newline-delimited JSON over a Unix domain socket.
/// Clients connect and receive a replay of recent lines followed by live updates.
final class TranscriptSocketServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.vibe.ripcord.transcriptsocket")

    // Listening socket
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    // Connected clients
    private var clientFDs: [Int32] = []
    private let clientLock = NSLock()

    // Ring buffer for replay-on-connect
    private var replayBuffer: [String] = []
    private var replayHead: Int = 0
    private var replayCount: Int = 0
    private let replayCapacity: Int

    /// Number of currently connected clients.
    var connectedClientCount: Int {
        clientLock.withLock { clientFDs.count }
    }

    init(path: String = "/tmp/ripcord-transcript.sock", replayCapacity: Int = 1000) {
        self.socketPath = path
        self.replayCapacity = replayCapacity
        self.replayBuffer = [String](repeating: "", count: replayCapacity)
    }

    // MARK: - Lifecycle

    func start() throws {
        // Remove stale socket file
        unlink(socketPath)

        // Create socket
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(listenFD)
            listenFD = -1
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(listenFD)
            listenFD = -1
            throw SocketError.bindFailed(err)
        }

        // Listen
        guard listen(listenFD, 5) == 0 else {
            let err = errno
            close(listenFD)
            listenFD = -1
            unlink(socketPath)
            throw SocketError.listenFailed(err)
        }

        // Non-blocking listen FD for DispatchSource
        let flags = fcntl(listenFD, F_GETFL)
        _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)

        // Accept loop via DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
        }
        source.resume()
        acceptSource = source

        logger.info("Transcript socket listening at \(self.socketPath)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        clientLock.withLock {
            for fd in clientFDs { close(fd) }
            clientFDs.removeAll()
        }

        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)

        logger.info("Transcript socket stopped")
    }

    deinit {
        stop()
    }

    // MARK: - Broadcasting

    /// Broadcast a JSONL line to all connected clients and append to replay buffer.
    func broadcast(_ line: String) {
        let message = line.hasSuffix("\n") ? line : line + "\n"

        clientLock.withLock {
            // Append to ring buffer
            replayBuffer[replayHead] = message
            replayHead = (replayHead + 1) % replayCapacity
            if replayCount < replayCapacity { replayCount += 1 }

            // Send to all clients, collecting dead ones
            var deadIndices: [Int] = []
            for (i, fd) in clientFDs.enumerated() {
                if !sendToClient(fd, message: message) {
                    close(fd)
                    deadIndices.append(i)
                }
            }

            // Remove dead clients in reverse order
            for i in deadIndices.reversed() {
                clientFDs.remove(at: i)
            }
        }
    }

    // MARK: - Private

    private func acceptClients() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }

            // Set non-blocking
            let flags = fcntl(clientFD, F_GETFL)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

            // Ignore SIGPIPE for this process (if not already)
            signal(SIGPIPE, SIG_IGN)

            clientLock.withLock {
                // Send replay buffer to new client
                let replayLines = replayLines()
                for line in replayLines {
                    if !sendToClient(clientFD, message: line) {
                        close(clientFD)
                        return
                    }
                }
                clientFDs.append(clientFD)
            }

            logger.info("Client connected (fd=\(clientFD), total=\(self.clientFDs.count))")
        }
    }

    /// Returns replay buffer contents in chronological order.
    /// Must be called under clientLock.
    private func replayLines() -> [String] {
        guard replayCount > 0 else { return [] }

        var lines: [String] = []
        lines.reserveCapacity(replayCount)

        let start = (replayHead - replayCount + replayCapacity) % replayCapacity
        for i in 0..<replayCount {
            let idx = (start + i) % replayCapacity
            lines.append(replayBuffer[idx])
        }
        return lines
    }

    /// Send a string to a client FD. Returns false if the client should be removed.
    @discardableResult
    private func sendToClient(_ fd: Int32, message: String) -> Bool {
        message.withCString { ptr in
            let len = strlen(ptr)
            let written = write(fd, ptr, len)
            if written < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Client can't keep up — drop it
                    return false
                }
                if err == EPIPE || err == ECONNRESET || err == ENOTCONN {
                    return false
                }
                return false
            }
            return true
        }
    }

    // MARK: - Errors

    enum SocketError: Error, LocalizedError {
        case createFailed(Int32)
        case pathTooLong
        case bindFailed(Int32)
        case listenFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let e): "Failed to create socket: \(String(cString: strerror(e)))"
            case .pathTooLong: "Socket path exceeds maximum length"
            case .bindFailed(let e): "Failed to bind socket: \(String(cString: strerror(e)))"
            case .listenFailed(let e): "Failed to listen on socket: \(String(cString: strerror(e)))"
            }
        }
    }
}
