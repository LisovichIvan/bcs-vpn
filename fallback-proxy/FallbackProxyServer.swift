import Darwin
import Dispatch
import Foundation

private enum ProxyError: Error {
    case invalidGreeting
    case unsupportedAuthentication
    case invalidRequest
    case unsupportedCommand
    case unsupportedAddressType
    case connectionFailed
    case connectionClosed
    case responseAlreadySent
}

struct FallbackProxyConfiguration {
    var listenPort = 8889
    var upstreamHost = "127.0.0.1"
    var upstreamPort = 8890
    var upstreamTimeoutMilliseconds = 1_000
    var directConnectTimeoutMilliseconds = 10_000

    static func parse(arguments: [String]) -> FallbackProxyConfiguration {
        var configuration = FallbackProxyConfiguration()
        var argumentIndex = 1

        while argumentIndex < arguments.count {
            guard argumentIndex + 1 < arguments.count else {
                fatalError("Missing value for \(arguments[argumentIndex])")
            }

            let value = arguments[argumentIndex + 1]
            switch arguments[argumentIndex] {
            case "--listen-port":
                configuration.listenPort = requiredPort(value)
            case "--upstream-host":
                configuration.upstreamHost = value
            case "--upstream-port":
                configuration.upstreamPort = requiredPort(value)
            case "--upstream-timeout-milliseconds":
                configuration.upstreamTimeoutMilliseconds = requiredPositiveInteger(value)
            case "--direct-timeout-milliseconds":
                configuration.directConnectTimeoutMilliseconds = requiredPositiveInteger(value)
            default:
                fatalError("Unknown argument: \(arguments[argumentIndex])")
            }

            argumentIndex += 2
        }

        return configuration
    }

    private static func requiredPort(_ value: String) -> Int {
        let port = requiredPositiveInteger(value)
        guard port <= 65_535 else {
            fatalError("Invalid port: \(value)")
        }
        return port
    }

    private static func requiredPositiveInteger(_ value: String) -> Int {
        guard let number = Int(value), number > 0 else {
            fatalError("Expected positive integer: \(value)")
        }
        return number
    }
}

private struct SocksRequest {
    let destinationHost: String
    let destinationPort: Int
    let encodedRequest: [UInt8]
}

private enum UpstreamResult {
    case unavailable
    case failed
    case response(socketDescriptor: Int32, reply: [UInt8])
}

private final class ClientConnectionLimiter {
    private let maximumClientCount: Int
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var activeClientCount = 0

    init(maximumClientCount: Int) {
        self.maximumClientCount = maximumClientCount
        semaphore = DispatchSemaphore(value: maximumClientCount)
    }

    func tryAcquire() -> Bool {
        guard semaphore.wait(timeout: .now()) == .success else {
            return false
        }

        lock.lock()
        activeClientCount += 1
        lock.unlock()
        return true
    }

    func release() {
        lock.lock()
        activeClientCount -= 1
        lock.unlock()
        semaphore.signal()
    }

    func statusDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "active=\(activeClientCount) limit=\(maximumClientCount)"
    }
}

private let logLock = NSLock()
private let clientConnectionLimiter = ClientConnectionLimiter(maximumClientCount: 512)
private let clientHandshakeTimeoutSeconds = 5
private let relayIdleTimeoutMilliseconds: Int32 = 3_600_000

private func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(timestamp) \(message)\n".utf8))
}

private func readExactly(socketDescriptor: Int32, count: Int) throws -> [UInt8] {
    var result = [UInt8](repeating: 0, count: count)
    var bytesRead = 0

    while bytesRead < count {
        let currentRead = result.withUnsafeMutableBytes { buffer in
            Darwin.recv(
                socketDescriptor,
                buffer.baseAddress!.advanced(by: bytesRead),
                count - bytesRead,
                0
            )
        }

        if currentRead == 0 {
            throw ProxyError.connectionClosed
        }
        if currentRead < 0 {
            if errno == EINTR {
                continue
            }
            throw ProxyError.connectionFailed
        }
        bytesRead += currentRead
    }

    return result
}

private func writeAll(socketDescriptor: Int32, bytes: [UInt8]) throws {
    var bytesWritten = 0

    while bytesWritten < bytes.count {
        let currentWrite = bytes.withUnsafeBytes { buffer in
            Darwin.send(
                socketDescriptor,
                buffer.baseAddress!.advanced(by: bytesWritten),
                bytes.count - bytesWritten,
                0
            )
        }

        if currentWrite < 0 {
            if errno == EINTR {
                continue
            }
            throw ProxyError.connectionFailed
        }
        bytesWritten += currentWrite
    }
}

private func setSocketTimeoutMilliseconds(socketDescriptor: Int32, milliseconds: Int) {
    var timeout = timeval(
        tv_sec: milliseconds / 1_000,
        tv_usec: Int32(milliseconds % 1_000) * 1_000
    )
    let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength)
    setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength)
}

private func clearSocketTimeout(socketDescriptor: Int32) {
    setSocketTimeoutMilliseconds(socketDescriptor: socketDescriptor, milliseconds: 0)
}

private func connectToHost(
    host: String,
    port: Int,
    timeoutMilliseconds: Int
) -> Int32? {
    var addressHints = addrinfo()
    addressHints.ai_family = AF_UNSPEC
    addressHints.ai_socktype = SOCK_STREAM
    addressHints.ai_protocol = IPPROTO_TCP

    var addressResults: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &addressHints, &addressResults) == 0 else {
        return nil
    }
    defer { freeaddrinfo(addressResults) }

    var currentAddress = addressResults
    while let address = currentAddress {
        defer { currentAddress = address.pointee.ai_next }

        let socketDescriptor = Darwin.socket(
            address.pointee.ai_family,
            address.pointee.ai_socktype,
            address.pointee.ai_protocol
        )
        if socketDescriptor < 0 {
            continue
        }

        let originalFlags = fcntl(socketDescriptor, F_GETFL, 0)
        if originalFlags < 0 || fcntl(socketDescriptor, F_SETFL, originalFlags | O_NONBLOCK) < 0 {
            Darwin.close(socketDescriptor)
            continue
        }

        let connectionResult = Darwin.connect(
            socketDescriptor,
            address.pointee.ai_addr,
            address.pointee.ai_addrlen
        )

        if connectionResult == 0 {
            _ = fcntl(socketDescriptor, F_SETFL, originalFlags)
            return socketDescriptor
        }

        if errno != EINPROGRESS {
            Darwin.close(socketDescriptor)
            continue
        }

        var pollDescriptor = pollfd(
            fd: socketDescriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(timeoutMilliseconds))
        if pollResult <= 0 {
            Darwin.close(socketDescriptor)
            continue
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let socketOptionResult = getsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        )
        if socketOptionResult == 0 && socketError == 0 {
            _ = fcntl(socketDescriptor, F_SETFL, originalFlags)
            return socketDescriptor
        }

        Darwin.close(socketDescriptor)
    }

    return nil
}

private func performClientHandshake(socketDescriptor: Int32) throws {
    let greeting = try readExactly(socketDescriptor: socketDescriptor, count: 2)
    guard greeting[0] == 5 else {
        throw ProxyError.invalidGreeting
    }

    let authenticationMethods = try readExactly(
        socketDescriptor: socketDescriptor,
        count: Int(greeting[1])
    )
    guard authenticationMethods.contains(0) else {
        try writeAll(socketDescriptor: socketDescriptor, bytes: [5, 255])
        throw ProxyError.responseAlreadySent
    }

    try writeAll(socketDescriptor: socketDescriptor, bytes: [5, 0])
}

private func readClientRequest(socketDescriptor: Int32) throws -> SocksRequest {
    let requestHeader = try readExactly(socketDescriptor: socketDescriptor, count: 4)
    guard requestHeader[0] == 5, requestHeader[2] == 0 else {
        sendReply(socketDescriptor: socketDescriptor, responseCode: 1)
        throw ProxyError.responseAlreadySent
    }
    guard requestHeader[1] == 1 else {
        sendReply(socketDescriptor: socketDescriptor, responseCode: 7)
        throw ProxyError.responseAlreadySent
    }

    let addressType = requestHeader[3]
    let addressBytes: [UInt8]
    let destinationHost: String

    switch addressType {
    case 1:
        addressBytes = try readExactly(socketDescriptor: socketDescriptor, count: 4)
        destinationHost = addressBytes.map(String.init).joined(separator: ".")
    case 3:
        let domainLength = try readExactly(socketDescriptor: socketDescriptor, count: 1)
        let domainBytes = try readExactly(
            socketDescriptor: socketDescriptor,
            count: Int(domainLength[0])
        )
        addressBytes = domainLength + domainBytes
        guard let decodedDomain = String(bytes: domainBytes, encoding: .utf8) else {
            sendReply(socketDescriptor: socketDescriptor, responseCode: 1)
            throw ProxyError.responseAlreadySent
        }
        destinationHost = decodedDomain
    case 4:
        addressBytes = try readExactly(socketDescriptor: socketDescriptor, count: 16)
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            buffer.copyBytes(from: addressBytes)
        }
        var addressBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &addressBuffer, socklen_t(addressBuffer.count)) != nil else {
            sendReply(socketDescriptor: socketDescriptor, responseCode: 1)
            throw ProxyError.responseAlreadySent
        }
        destinationHost = String(cString: addressBuffer)
    default:
        sendReply(socketDescriptor: socketDescriptor, responseCode: 8)
        throw ProxyError.responseAlreadySent
    }

    let portBytes = try readExactly(socketDescriptor: socketDescriptor, count: 2)
    let destinationPort = Int(portBytes[0]) << 8 | Int(portBytes[1])
    let encodedRequest = requestHeader + addressBytes + portBytes

    return SocksRequest(
        destinationHost: destinationHost,
        destinationPort: destinationPort,
        encodedRequest: encodedRequest
    )
}

private func sendReply(socketDescriptor: Int32, responseCode: UInt8) {
    try? writeAll(
        socketDescriptor: socketDescriptor,
        bytes: [5, responseCode, 0, 1, 0, 0, 0, 0, 0, 0]
    )
}

private func sendDirectSuccessReply(clientSocket: Int32, directSocket: Int32) -> Bool {
    var boundAddress = sockaddr_storage()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    guard getsockname(
        directSocket,
        withUnsafeMutablePointer(to: &boundAddress) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
        },
        &boundAddressLength
    ) == 0 else {
        sendReply(socketDescriptor: clientSocket, responseCode: 1)
        return false
    }

    let response: [UInt8]
    if boundAddress.ss_family == sa_family_t(AF_INET) {
        let address = withUnsafePointer(to: &boundAddress) {
            UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr_in.self).pointee
        }
        let addressBytes = withUnsafeBytes(of: address.sin_addr) { Array($0) }
        let port = UInt16(bigEndian: address.sin_port)
        response = [5, 0, 0, 1] + addressBytes + [UInt8(port >> 8), UInt8(port & 255)]
    } else if boundAddress.ss_family == sa_family_t(AF_INET6) {
        let address = withUnsafePointer(to: &boundAddress) {
            UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr_in6.self).pointee
        }
        let addressBytes = withUnsafeBytes(of: address.sin6_addr) { Array($0) }
        let port = UInt16(bigEndian: address.sin6_port)
        response = [5, 0, 0, 4] + addressBytes + [UInt8(port >> 8), UInt8(port & 255)]
    } else {
        sendReply(socketDescriptor: clientSocket, responseCode: 1)
        return false
    }

    do {
        try writeAll(socketDescriptor: clientSocket, bytes: response)
        return true
    } catch {
        return false
    }
}

private func readUpstreamReply(socketDescriptor: Int32) throws -> [UInt8] {
    let replyHeader = try readExactly(socketDescriptor: socketDescriptor, count: 4)
    guard replyHeader[0] == 5, replyHeader[1] <= 8, replyHeader[2] == 0 else {
        throw ProxyError.invalidRequest
    }

    let addressTail: [UInt8]
    switch replyHeader[3] {
    case 1:
        addressTail = try readExactly(socketDescriptor: socketDescriptor, count: 6)
    case 3:
        let domainLength = try readExactly(socketDescriptor: socketDescriptor, count: 1)
        addressTail = domainLength + (try readExactly(
            socketDescriptor: socketDescriptor,
            count: Int(domainLength[0]) + 2
        ))
    case 4:
        addressTail = try readExactly(socketDescriptor: socketDescriptor, count: 18)
    default:
        throw ProxyError.unsupportedAddressType
    }

    return replyHeader + addressTail
}

private func requestThroughUpstream(
    request: SocksRequest,
    configuration: FallbackProxyConfiguration
) -> UpstreamResult {
    guard let upstreamSocket = connectToHost(
        host: configuration.upstreamHost,
        port: configuration.upstreamPort,
        timeoutMilliseconds: configuration.upstreamTimeoutMilliseconds
    ) else {
        return .unavailable
    }

    setSocketTimeoutMilliseconds(
        socketDescriptor: upstreamSocket,
        milliseconds: configuration.upstreamTimeoutMilliseconds
    )

    do {
        try writeAll(socketDescriptor: upstreamSocket, bytes: [5, 1, 0])
        let authenticationReply = try readExactly(socketDescriptor: upstreamSocket, count: 2)
        guard authenticationReply == [5, 0] else {
            throw ProxyError.unsupportedAuthentication
        }
        try writeAll(socketDescriptor: upstreamSocket, bytes: request.encodedRequest)
        let upstreamReply = try readUpstreamReply(socketDescriptor: upstreamSocket)
        clearSocketTimeout(socketDescriptor: upstreamSocket)
        return .response(socketDescriptor: upstreamSocket, reply: upstreamReply)
    } catch {
        Darwin.close(upstreamSocket)
        return .failed
    }
}

private func relayDirection(sourceSocket: Int32, destinationSocket: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65_536)

    while true {
        let receivedBytes = buffer.withUnsafeMutableBytes { bytes in
            Darwin.recv(sourceSocket, bytes.baseAddress, bytes.count, 0)
        }
        if receivedBytes == 0 {
            return
        }
        if receivedBytes < 0 {
            if errno == EINTR {
                continue
            }
            return
        }

        let payload = Array(buffer[0..<receivedBytes])
        if (try? writeAll(socketDescriptor: destinationSocket, bytes: payload)) == nil {
            return
        }
    }
}

private func relaySockets(firstSocket: Int32, secondSocket: Int32) {
    setSocketTimeoutMilliseconds(
        socketDescriptor: firstSocket,
        milliseconds: Int(relayIdleTimeoutMilliseconds)
    )
    setSocketTimeoutMilliseconds(
        socketDescriptor: secondSocket,
        milliseconds: Int(relayIdleTimeoutMilliseconds)
    )

    let relayGroup = DispatchGroup()
    relayGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        relayDirection(sourceSocket: firstSocket, destinationSocket: secondSocket)
        Darwin.shutdown(secondSocket, SHUT_WR)
        relayGroup.leave()
    }
    relayGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        relayDirection(sourceSocket: secondSocket, destinationSocket: firstSocket)
        Darwin.shutdown(firstSocket, SHUT_WR)
        relayGroup.leave()
    }
    relayGroup.wait()
}

private func handleClient(socketDescriptor: Int32, configuration: FallbackProxyConfiguration) {
    defer { Darwin.close(socketDescriptor) }

    do {
        setSocketTimeoutMilliseconds(
            socketDescriptor: socketDescriptor,
            milliseconds: clientHandshakeTimeoutSeconds * 1_000
        )
        try performClientHandshake(socketDescriptor: socketDescriptor)
        let request = try readClientRequest(socketDescriptor: socketDescriptor)
        clearSocketTimeout(socketDescriptor: socketDescriptor)

        switch requestThroughUpstream(
            request: request,
            configuration: configuration
        ) {
        case let .response(upstreamSocket, upstreamReply):
            defer { Darwin.close(upstreamSocket) }
            try writeAll(socketDescriptor: socketDescriptor, bytes: upstreamReply)
            guard upstreamReply[1] == 0 else {
                return
            }

            log("mode=vpn destination=\(request.destinationHost):\(request.destinationPort)")
            relaySockets(firstSocket: socketDescriptor, secondSocket: upstreamSocket)
            return
        case .unavailable:
            break
        case .failed:
            sendReply(socketDescriptor: socketDescriptor, responseCode: 1)
            return
        }

        guard let directSocket = connectToHost(
            host: request.destinationHost,
            port: request.destinationPort,
            timeoutMilliseconds: configuration.directConnectTimeoutMilliseconds
        ) else {
            sendReply(socketDescriptor: socketDescriptor, responseCode: 4)
            return
        }
        defer { Darwin.close(directSocket) }

        guard sendDirectSuccessReply(
            clientSocket: socketDescriptor,
            directSocket: directSocket
        ) else {
            return
        }
        log("mode=direct destination=\(request.destinationHost):\(request.destinationPort)")
        relaySockets(firstSocket: socketDescriptor, secondSocket: directSocket)
    } catch ProxyError.responseAlreadySent {
        log("connection-error=response-already-sent")
    } catch {
        log("connection-error=\(error)")
    }
}

enum FallbackProxyServerError: LocalizedError {
    case socketCreationFailed
    case socketConfigurationFailed
    case bindFailed(port: Int, errorNumber: Int32)
    case listenFailed(port: Int)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Не удалось создать сокет fallback SOCKS5."
        case .socketConfigurationFailed:
            return "Не удалось настроить сокет fallback SOCKS5."
        case let .bindFailed(port, errorNumber):
            return "Не удалось занять 127.0.0.1:\(port), errno=\(errorNumber)."
        case let .listenFailed(port):
            return "Не удалось запустить прослушивание 127.0.0.1:\(port)."
        }
    }
}

final class FallbackProxyServer {
    private let configuration: FallbackProxyConfiguration
    private var serverSocket: Int32 = -1

    init(configuration: FallbackProxyConfiguration = FallbackProxyConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
        }
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)

        let createdServerSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard createdServerSocket >= 0 else {
            throw FallbackProxyServerError.socketCreationFailed
        }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            createdServerSocket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(createdServerSocket)
            throw FallbackProxyServerError.socketConfigurationFailed
        }

        var listenAddress = sockaddr_in()
        listenAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        listenAddress.sin_family = sa_family_t(AF_INET)
        listenAddress.sin_port = in_port_t(configuration.listenPort).bigEndian
        listenAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &listenAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    createdServerSocket,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let bindErrorNumber = errno
            Darwin.close(createdServerSocket)
            throw FallbackProxyServerError.bindFailed(
                port: configuration.listenPort,
                errorNumber: bindErrorNumber
            )
        }
        guard Darwin.listen(createdServerSocket, 128) == 0 else {
            Darwin.close(createdServerSocket)
            throw FallbackProxyServerError.listenFailed(port: configuration.listenPort)
        }

        serverSocket = createdServerSocket
        log(
            "listening=127.0.0.1:\(configuration.listenPort) "
                + "upstream=\(configuration.upstreamHost):\(configuration.upstreamPort)"
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptClients()
        }
    }

    private func acceptClients() {
        while true {
            let clientSocket = Darwin.accept(serverSocket, nil, nil)
            if clientSocket < 0 {
                if errno == EINTR {
                    continue
                }
                log("accept-error=\(errno)")
                usleep(100_000)
                continue
            }

            if !clientConnectionLimiter.tryAcquire() {
                log("client-limit-reached \(clientConnectionLimiter.statusDescription())")
                Darwin.close(clientSocket)
                continue
            }

            DispatchQueue.global(qos: .utility).async { [configuration] in
                defer { clientConnectionLimiter.release() }
                handleClient(socketDescriptor: clientSocket, configuration: configuration)
            }
        }
    }
}
