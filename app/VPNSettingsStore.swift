import Darwin
import Foundation

struct VPNSettings: Codable, Equatable {
    let serverURL: String
    let username: String
    let rsaPIN: String
    let certificateSHA1: String
    let serverCertificatePin: String

    static let empty = VPNSettings(
        serverURL: "",
        username: "",
        rsaPIN: "",
        certificateSHA1: "",
        serverCertificatePin: ""
    )

    func validated() throws -> VPNSettings {
        let normalizedSettings = VPNSettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            rsaPIN: rsaPIN.trimmingCharacters(in: .whitespacesAndNewlines),
            certificateSHA1: certificateSHA1
                .filter { $0 != ":" && !$0.isWhitespace }
                .uppercased(),
            serverCertificatePin: serverCertificatePin
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let values = [
            normalizedSettings.serverURL,
            normalizedSettings.username,
            normalizedSettings.rsaPIN,
            normalizedSettings.certificateSHA1,
            normalizedSettings.serverCertificatePin,
        ]
        guard values.allSatisfy({ !$0.isEmpty }) else {
            throw VPNSettingsStoreError.invalidSetting("Заполните все поля.")
        }
        guard values.allSatisfy({ value in
            !value.unicodeScalars.contains(where: { scalar in
                scalar.value < 32 || scalar.value == 127
            })
        }) else {
            throw VPNSettingsStoreError.invalidSetting(
                "Значения не должны содержать управляющие символы."
            )
        }

        let serverURLComponents = URLComponents(string: normalizedSettings.serverURL)
        guard serverURLComponents?.scheme?.lowercased() == "https",
              serverURLComponents?.host?.isEmpty == false else {
            throw VPNSettingsStoreError.invalidSetting("Шлюз должен быть корректным адресом HTTPS.")
        }
        guard normalizedSettings.rsaPIN.unicodeScalars.allSatisfy({
            $0.value >= 48 && $0.value <= 57
        }) else {
            throw VPNSettingsStoreError.invalidSetting("Постоянный PIN должен содержать только цифры.")
        }

        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard normalizedSettings.certificateSHA1.count == 40,
              normalizedSettings.certificateSHA1.unicodeScalars.allSatisfy({
                  hexadecimalCharacters.contains($0)
              }) else {
            throw VPNSettingsStoreError.invalidSetting(
                "SHA-1 сертификата должен содержать 40 шестнадцатеричных символов."
            )
        }

        let serverCertificatePinPrefix = "pin-sha256:"
        let serverCertificateDigest = String(
            normalizedSettings.serverCertificatePin.dropFirst(serverCertificatePinPrefix.count)
        )
        guard normalizedSettings.serverCertificatePin.hasPrefix(serverCertificatePinPrefix),
              let decodedDigest = Data(base64Encoded: serverCertificateDigest),
              decodedDigest.count == 32 else {
            throw VPNSettingsStoreError.invalidSetting(
                "Закрепление сертификата сервера должно содержать полный SHA-256 в Base64."
            )
        }

        return normalizedSettings
    }
}

enum VPNSettingsStoreError: LocalizedError {
    case invalidSetting(String)
    case unsafeConfigurationFile(String)
    case invalidConfigurationFile(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSetting(message):
            return message
        case let .unsafeConfigurationFile(fileName):
            return "Файл \(fileName) должен быть обычным файлом текущего пользователя с правами 600."
        case let .invalidConfigurationFile(fileName):
            return "Не удалось прочитать настройки из \(fileName)."
        case let .fileOperationFailed(details):
            return "Не удалось сохранить настройки: \(details)"
        }
    }
}

final class VPNSettingsStore {
    let configurationFileURL: URL
    private let legacyConfigurationFileURL: URL

    init(projectDirectory: URL) {
        configurationFileURL = projectDirectory.appendingPathComponent(
            "vpn-settings.plist",
            isDirectory: false
        )
        legacyConfigurationFileURL = projectDirectory.appendingPathComponent(
            ".env",
            isDirectory: false
        )
    }

    func load() throws -> VPNSettings {
        if let configurationData = try readSecureFile(at: configurationFileURL) {
            return try decodePropertyList(
                configurationData,
                fileName: configurationFileURL.lastPathComponent
            )
        }
        guard let legacyData = try readSecureFile(at: legacyConfigurationFileURL) else {
            return .empty
        }

        let migratedSettings = try decodeLegacyConfiguration(legacyData).validated()
        _ = try save(migratedSettings)
        return migratedSettings
    }

    func load(from fileURL: URL) throws -> VPNSettings {
        guard let data = try readRegularFile(at: fileURL) else {
            throw VPNSettingsStoreError.invalidConfigurationFile(fileURL.lastPathComponent)
        }
        return try decodePropertyList(data, fileName: fileURL.lastPathComponent)
    }

    func save(_ settings: VPNSettings) throws -> VPNSettings {
        let normalizedSettings = try settings.validated()
        _ = try readSecureFile(at: configurationFileURL)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let configurationData: Data
        do {
            configurationData = try encoder.encode(normalizedSettings)
        } catch {
            throw VPNSettingsStoreError.fileOperationFailed(error.localizedDescription)
        }
        try replaceConfigurationFile(with: configurationData, at: configurationFileURL)
        return normalizedSettings
    }

    func export(_ settings: VPNSettings, to fileURL: URL) throws {
        let normalizedSettings = try settings.validated()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let configurationData: Data
        do {
            configurationData = try encoder.encode(normalizedSettings)
        } catch {
            throw VPNSettingsStoreError.fileOperationFailed(error.localizedDescription)
        }
        try replaceConfigurationFile(with: configurationData, at: fileURL)
    }

    private func decodePropertyList(_ data: Data, fileName: String) throws -> VPNSettings {
        do {
            return try PropertyListDecoder().decode(VPNSettings.self, from: data).validated()
        } catch let error as VPNSettingsStoreError {
            throw error
        } catch {
            throw VPNSettingsStoreError.invalidConfigurationFile(
                fileName
            )
        }
    }

    private func readSecureFile(at fileURL: URL) throws -> Data? {
        try readFile(at: fileURL, requireSecurePermissions: true)
    }

    private func readRegularFile(at fileURL: URL) throws -> Data? {
        try readFile(at: fileURL, requireSecurePermissions: false)
    }

    private func readFile(at fileURL: URL, requireSecurePermissions: Bool) throws -> Data? {
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fileDescriptor < 0 {
            if errno == ENOENT {
                return nil
            }
            throw VPNSettingsStoreError.unsafeConfigurationFile(fileURL.lastPathComponent)
        }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0,
              fileInformation.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fileDescriptor)
            throw VPNSettingsStoreError.unsafeConfigurationFile(fileURL.lastPathComponent)
        }
        if requireSecurePermissions && (
            fileInformation.st_uid != geteuid() ||
            fileInformation.st_mode & mode_t(0o077) != 0
        ) {
            Darwin.close(fileDescriptor)
            throw VPNSettingsStoreError.unsafeConfigurationFile(fileURL.lastPathComponent)
        }

        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            return try fileHandle.readToEnd() ?? Data()
        } catch {
            throw VPNSettingsStoreError.invalidConfigurationFile(fileURL.lastPathComponent)
        }
    }

    private func decodeLegacyConfiguration(_ data: Data) throws -> VPNSettings {
        guard let content = String(data: data, encoding: .utf8) else {
            throw VPNSettingsStoreError.invalidConfigurationFile(
                legacyConfigurationFileURL.lastPathComponent
            )
        }

        let settingKeys = Set([
            "OPENCONNECT_URL",
            "OPENCONNECT_USER",
            "OPENCONNECT_RSA_PIN",
            "OPENCONNECT_CERTIFICATE_SHA1",
            "OPENCONNECT_SERVER_CERTIFICATE_PIN",
        ])
        var valuesByKey: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            var assignment = line.trimmingCharacters(in: .whitespaces)
            guard !assignment.isEmpty, !assignment.hasPrefix("#") else {
                continue
            }
            if assignment.hasPrefix("export ") {
                assignment = String(assignment.dropFirst("export ".count))
            }
            guard let separatorIndex = assignment.firstIndex(of: "=") else {
                continue
            }
            let key = assignment[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            guard settingKeys.contains(key) else {
                continue
            }
            let rawValue = String(assignment[assignment.index(after: separatorIndex)...])
            guard let value = decodeLegacyShellValue(rawValue) else {
                throw VPNSettingsStoreError.invalidConfigurationFile(
                    legacyConfigurationFileURL.lastPathComponent
                )
            }
            valuesByKey[key] = value
        }

        let legacyServerURL = valuesByKey["OPENCONNECT_URL", default: ""]
        let migratedServerURL = legacyServerURL.contains("://")
            ? legacyServerURL
            : "https://\(legacyServerURL)"
        return VPNSettings(
            serverURL: migratedServerURL,
            username: valuesByKey["OPENCONNECT_USER", default: ""],
            rsaPIN: valuesByKey["OPENCONNECT_RSA_PIN", default: ""],
            certificateSHA1: valuesByKey["OPENCONNECT_CERTIFICATE_SHA1", default: ""],
            serverCertificatePin: valuesByKey["OPENCONNECT_SERVER_CERTIFICATE_PIN", default: ""]
        )
    }

    private func decodeLegacyShellValue(_ rawValue: String) -> String? {
        enum QuoteState {
            case unquoted
            case singleQuoted
            case doubleQuoted
        }

        let characters = Array(rawValue)
        var decodedValue = ""
        var quoteState = QuoteState.unquoted
        var characterIndex = 0
        while characterIndex < characters.count {
            let character = characters[characterIndex]
            switch quoteState {
            case .unquoted:
                if character == "'" {
                    quoteState = .singleQuoted
                } else if character == "\"" {
                    quoteState = .doubleQuoted
                } else if character == "\\" {
                    characterIndex += 1
                    guard characterIndex < characters.count else {
                        return nil
                    }
                    decodedValue.append(characters[characterIndex])
                } else if character.isWhitespace {
                    let remainder = String(characters[characterIndex...])
                        .trimmingCharacters(in: .whitespaces)
                    guard remainder.isEmpty || remainder.hasPrefix("#") else {
                        return nil
                    }
                    return decodedValue
                } else if character == "$" || character == "`" {
                    return nil
                } else {
                    decodedValue.append(character)
                }
            case .singleQuoted:
                if character == "'" {
                    quoteState = .unquoted
                } else {
                    decodedValue.append(character)
                }
            case .doubleQuoted:
                if character == "\"" {
                    quoteState = .unquoted
                } else if character == "\\" {
                    let nextCharacterIndex = characterIndex + 1
                    guard nextCharacterIndex < characters.count else {
                        return nil
                    }
                    let nextCharacter = characters[nextCharacterIndex]
                    if nextCharacter == "$" || nextCharacter == "`" ||
                        nextCharacter == "\"" || nextCharacter == "\\" {
                        decodedValue.append(nextCharacter)
                        characterIndex = nextCharacterIndex
                    } else {
                        decodedValue.append(character)
                    }
                } else if character == "$" || character == "`" {
                    return nil
                } else {
                    decodedValue.append(character)
                }
            }
            characterIndex += 1
        }
        return quoteState == .unquoted ? decodedValue : nil
    }

    private func replaceConfigurationFile(with data: Data, at destinationURL: URL) throws {
        let temporaryFileURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".vpn-settings.plist.\(UUID().uuidString)",
                isDirectory: false
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }

        var temporaryFileDescriptor = temporaryFileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard temporaryFileDescriptor >= 0 else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
        defer {
            if temporaryFileDescriptor >= 0 {
                Darwin.close(temporaryFileDescriptor)
            }
        }

        let writeSucceeded = data.withUnsafeBytes { buffer -> Bool in
            var writtenByteCount = 0
            while writtenByteCount < buffer.count {
                let currentWriteCount = Darwin.write(
                    temporaryFileDescriptor,
                    buffer.baseAddress?.advanced(by: writtenByteCount),
                    buffer.count - writtenByteCount
                )
                if currentWriteCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                writtenByteCount += currentWriteCount
            }
            return true
        }
        guard writeSucceeded, fsync(temporaryFileDescriptor) == 0 else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
        guard Darwin.close(temporaryFileDescriptor) == 0 else {
            temporaryFileDescriptor = -1
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
        temporaryFileDescriptor = -1

        let renameResult = temporaryFileURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { configurationPath in
                Darwin.rename(temporaryPath, configurationPath)
            }
        }
        guard renameResult == 0 else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
    }
}
