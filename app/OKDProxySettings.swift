import Darwin
import Foundation

struct OKDProxySettings: Codable, Equatable {
    let serverURL: String
    let token: String
    let username: String
    let password: String
    let namespace: String
    let podSelector: String
    let ports: String

    static let defaultPorts = "1424 1427 1428 1429 1430 1431 1432 1433 1434 1435 1436 1437 1438 1439 1440 1441 1442 1445 1446 1447 1449"
    static let empty = OKDProxySettings(
        serverURL: "https://okd.tusvc.bcs.ru:443",
        token: "",
        username: "",
        password: "",
        namespace: "crm-common",
        podSelector: "app=crm-db-proxy",
        ports: defaultPorts
    )

    func validated() throws -> OKDProxySettings {
        let normalized = OKDProxySettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            podSelector: podSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            ports: ports.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        )
        let requiredValues = [normalized.serverURL, normalized.namespace, normalized.podSelector, normalized.ports]
        guard requiredValues.allSatisfy({ !$0.isEmpty }) else {
            throw OKDProxySettingsError.invalidSetting("Заполните обязательные поля OKD Proxy.")
        }
        let hasToken = !normalized.token.isEmpty
        let hasLoginAndPassword = !normalized.username.isEmpty && !normalized.password.isEmpty
        guard hasToken || hasLoginAndPassword else {
            throw OKDProxySettingsError.invalidSetting("Укажите token либо логин и пароль OKD.")
        }
        guard normalized.username.isEmpty == normalized.password.isEmpty else {
            throw OKDProxySettingsError.invalidSetting("Логин и пароль OKD должны быть указаны вместе.")
        }
        let values = [normalized.serverURL, normalized.token, normalized.username, normalized.password, normalized.namespace, normalized.podSelector, normalized.ports]
        guard values.allSatisfy({ value in
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        }) else {
            throw OKDProxySettingsError.invalidSetting("Настройки OKD не должны содержать управляющие символы.")
        }
        guard let components = URLComponents(string: normalized.serverURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            throw OKDProxySettingsError.invalidSetting("Адрес OKD должен быть корректным HTTPS-адресом без query и fragment.")
        }
        if !normalized.token.isEmpty {
            guard normalized.token.range(of: "^[A-Za-z0-9._~+/=-]+$", options: .regularExpression) != nil else {
                throw OKDProxySettingsError.invalidSetting("Token OKD содержит недопустимые символы.")
            }
        }
        guard normalized.namespace.range(of: "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", options: .regularExpression) != nil else {
            throw OKDProxySettingsError.invalidSetting("Namespace OKD содержит недопустимые символы.")
        }
        guard normalized.podSelector.range(of: "^[A-Za-z0-9_.=:/,-]+$", options: .regularExpression) != nil else {
            throw OKDProxySettingsError.invalidSetting("Selector pod содержит недопустимые символы.")
        }
        let portValues = normalized.ports.split(separator: " ")
        guard !portValues.isEmpty,
              portValues.count <= 100,
              portValues.allSatisfy({ value in
                  guard let port = Int(value) else { return false }
                  return (1...65535).contains(port)
              }) else {
            throw OKDProxySettingsError.invalidSetting("Порты должны быть числами от 1 до 65535.")
        }
        return normalized
    }
}

// Keep settings files created by older versions readable.
extension OKDProxySettings {
    private enum CodingKeys: String, CodingKey {
        case serverURL, token, username, password, namespace, podSelector, ports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serverURL: try container.decode(String.self, forKey: .serverURL),
            token: try container.decodeIfPresent(String.self, forKey: .token) ?? "",
            username: try container.decodeIfPresent(String.self, forKey: .username) ?? "",
            password: try container.decodeIfPresent(String.self, forKey: .password) ?? "",
            namespace: try container.decode(String.self, forKey: .namespace),
            podSelector: try container.decode(String.self, forKey: .podSelector),
            ports: try container.decode(String.self, forKey: .ports)
        )
    }
}

enum OKDProxySettingsError: LocalizedError {
    case invalidSetting(String)
    case unsafeConfigurationFile
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSetting(message): return message
        case .unsafeConfigurationFile:
            return "Файл настроек OKD должен принадлежать текущему пользователю и иметь права 600."
        case let .fileOperationFailed(message): return "Не удалось сохранить настройки OKD: \(message)"
        }
    }
}

final class OKDProxySettingsStore {
    let configurationFileURL: URL

    init(dataDirectory: URL) {
        configurationFileURL = dataDirectory.appendingPathComponent("okd-proxy-settings.plist", isDirectory: false)
    }

    func load() throws -> OKDProxySettings {
        guard FileManager.default.fileExists(atPath: configurationFileURL.path) else {
            return .empty
        }
        let descriptor = configurationFileURL.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw OKDProxySettingsError.unsafeConfigurationFile }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0 else {
            Darwin.close(descriptor)
            throw OKDProxySettingsError.unsafeConfigurationFile
        }
        let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data: Data
        do {
            data = try fileHandle.readToEnd() ?? Data()
        } catch {
            throw OKDProxySettingsError.unsafeConfigurationFile
        }
        do {
            return try PropertyListDecoder().decode(OKDProxySettings.self, from: data).validated()
        } catch let error as OKDProxySettingsError {
            throw error
        } catch {
            throw OKDProxySettingsError.invalidSetting("Не удалось прочитать okd-proxy-settings.plist.")
        }
    }

    func save(_ settings: OKDProxySettings) throws -> OKDProxySettings {
        let normalized = try settings.validated()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(normalized)
        let directory = configurationFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".okd-proxy-settings.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw OKDProxySettingsError.fileOperationFailed("не удалось создать временный файл")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard Darwin.rename(temporaryURL.path, configurationFileURL.path) == 0 else {
            throw OKDProxySettingsError.fileOperationFailed(String(cString: strerror(errno)))
        }
        return normalized
    }
}
