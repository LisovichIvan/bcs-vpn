import Darwin
import Foundation

struct OKDPortForward: Equatable {
    let name: String
    let localPort: Int
    let destinationHost: String
    let destinationPort: Int

    var description: String {
        let host = destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost
        return "\(name)\n127.0.0.1:\(localPort) → pod:\(localPort) → \(host):\(destinationPort) (TCP)"
    }
}

struct OKDProxyConfiguration: Decodable {
    static let sourceURL = "https://gitlab.gitlab.bcs.ru/bcs-crm/crm-db-proxy/-/blob/develop/BCS.CRM.DBProxy/config.json"
    static let apiEndpoint = "projects/bcs-crm%2Fcrm-db-proxy/repository/files/BCS.CRM.DBProxy%2Fconfig.json/raw?ref=develop"
    let forwards: [OKDPortForward]

    var ports: String {
        Set(forwards.map(\.localPort)).sorted().map(String.init).joined(separator: " ")
    }

    private struct ServiceKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private enum EntryKey: String, CodingKey {
        case localport, forwardIp, forwardPort
        case transportProtocol = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ServiceKey.self)
        var forwards: [OKDPortForward] = []
        for key in container.allKeys where !key.stringValue.hasPrefix("_") {
            let entry = try container.nestedContainer(keyedBy: EntryKey.self, forKey: key)
            let transportProtocol = try entry.decode(String.self, forKey: .transportProtocol)
            guard transportProtocol == "tcp" else { continue }
            let localPort = try entry.decode(Int.self, forKey: .localport)
            let destinationHost = try entry.decode(String.self, forKey: .forwardIp)
            let destinationPort = try entry.decode(Int.self, forKey: .forwardPort)
            guard !key.stringValue.isEmpty,
                  !key.stringValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  (1...65535).contains(localPort), (1...65535).contains(destinationPort),
                  !destinationHost.isEmpty,
                  !destinationHost.unicodeScalars.contains(where: {
                      CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw OKDProxyConfigurationError.invalidConfiguration
            }
            forwards.append(OKDPortForward(
                name: key.stringValue, localPort: localPort,
                destinationHost: destinationHost, destinationPort: destinationPort
            ))
        }
        guard !forwards.isEmpty, Set(forwards.map(\.localPort)).count <= 100 else {
            throw OKDProxyConfigurationError.invalidConfiguration
        }
        self.forwards = forwards.sorted {
            $0.localPort == $1.localPort ? $0.name < $1.name : $0.localPort < $1.localPort
        }
    }
}

enum OKDProxyConfigurationError: LocalizedError {
    case missingGLab
    case downloadFailed
    case timedOut
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .missingGLab:
            return "Не найден glab. Установите GitLab CLI и выполните glab auth login --hostname gitlab.gitlab.bcs.ru."
        case .downloadFailed:
            return "Не удалось загрузить config.json из GitLab. Проверьте сеть и авторизацию: glab auth status --hostname gitlab.gitlab.bcs.ru."
        case .timedOut:
            return "Истекло время загрузки config.json из GitLab."
        case .invalidConfiguration:
            return "Некорректный config.json: нужны TCP-пробросы с портами 1–65535, адресами назначения и не более 100 уникальных портов."
        }
    }
}

// All lifecycle methods and completions run on the main thread. Only stdout is
// drained in the background, so a large response cannot block process exit.
final class OKDProxyConfigurationLoader {
    private let executableURL: URL?
    private let timeout: TimeInterval
    private var process: Process?
    private var timeoutWork: DispatchWorkItem?
    private var requestIdentifier: UUID?

    init(executableURL: URL? = OKDProxyConfigurationLoader.findGLab(), timeout: TimeInterval = 30) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    deinit {
        timeoutWork?.cancel()
        Self.terminate(process)
    }

    static func findGLab() -> URL? {
        for path in ["/opt/homebrew/bin/glab", "/usr/local/bin/glab", "/usr/bin/glab"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    func load(completion: @escaping (Result<OKDProxyConfiguration, Error>) -> Void) {
        cancel()
        guard let executableURL else {
            completion(.failure(OKDProxyConfigurationError.missingGLab))
            return
        }
        let command = Process()
        let output = Pipe()
        command.executableURL = executableURL
        command.arguments = ["api", "--hostname", "gitlab.gitlab.bcs.ru", OKDProxyConfiguration.apiEndpoint]
        command.standardOutput = output
        // Never expose glab's response body, headers or credentials in the UI/log.
        command.standardError = FileHandle.nullDevice
        command.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GLAB_DEBUG_HTTP"] = nil
        environment["GLAB_DEBUG"] = nil
        command.environment = environment
        let identifier = UUID()
        do {
            try command.run()
        } catch {
            completion(.failure(OKDProxyConfigurationError.downloadFailed))
            return
        }
        process = command
        requestIdentifier = identifier
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.requestIdentifier == identifier else { return }
            self.cancel()
            completion(.failure(OKDProxyConfigurationError.timedOut))
        }
        self.timeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try? output.fileHandleForReading.close()
            command.waitUntilExit()
            let result: Result<OKDProxyConfiguration, Error>
            if command.terminationStatus != 0 {
                result = .failure(OKDProxyConfigurationError.downloadFailed)
            } else {
                do {
                    result = .success(try JSONDecoder().decode(OKDProxyConfiguration.self, from: data))
                } catch {
                    result = .failure(OKDProxyConfigurationError.invalidConfiguration)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestIdentifier == identifier else { return }
                self.timeoutWork?.cancel()
                self.timeoutWork = nil
                self.process = nil
                self.requestIdentifier = nil
                completion(result)
            }
        }
    }

    func cancel() {
        requestIdentifier = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        Self.terminate(process)
        process = nil
    }

    private static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct OKDProxyRuntimeConfiguration: Encodable {
    let settings: OKDProxySettings
    let ports: String

    private enum CodingKeys: String, CodingKey { case ports }

    func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ports, forKey: .ports)
    }
}
