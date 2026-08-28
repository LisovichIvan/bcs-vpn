import Darwin
import Foundation

struct VPNSettings {
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
            !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
        }) else {
            throw VPNSettingsStoreError.invalidSetting("Значения не должны содержать переносы строк.")
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
        let serverCertificateDigest = normalizedSettings.serverCertificatePin
            .dropFirst(serverCertificatePinPrefix.count)
        guard normalizedSettings.serverCertificatePin.hasPrefix(serverCertificatePinPrefix),
              !serverCertificateDigest.isEmpty,
              !serverCertificateDigest.contains(where: { $0.isWhitespace }) else {
            throw VPNSettingsStoreError.invalidSetting(
                "Закрепление сертификата сервера должно начинаться с pin-sha256:."
            )
        }

        return normalizedSettings
    }
}

enum VPNSettingsStoreError: LocalizedError {
    case invalidSetting(String)
    case unsafeConfigurationFile
    case unsupportedConfigurationFile
    case invalidConfigurationValue(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSetting(message):
            return message
        case .unsafeConfigurationFile:
            return "Файл .env не должен быть символической ссылкой."
        case .unsupportedConfigurationFile:
            return "Путь .env должен указывать на обычный файл."
        case let .invalidConfigurationValue(key):
            return "Не удалось прочитать значение \(key) из .env."
        case let .fileOperationFailed(details):
            return "Не удалось сохранить .env: \(details)"
        }
    }
}

final class VPNSettingsStore {
    private static let settingKeys = [
        "OPENCONNECT_URL",
        "OPENCONNECT_USER",
        "OPENCONNECT_RSA_PIN",
        "OPENCONNECT_CERTIFICATE_SHA1",
        "OPENCONNECT_SERVER_CERTIFICATE_PIN",
    ]

    let configurationFileURL: URL

    init(projectDirectory: URL) {
        configurationFileURL = projectDirectory.appendingPathComponent(".env", isDirectory: false)
    }

    func load() throws -> VPNSettings {
        let configurationFileExists = try verifyConfigurationFileSafety()
        guard configurationFileExists else {
            return .empty
        }

        let content = try String(contentsOf: configurationFileURL, encoding: .utf8)
        var valuesByKey: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            guard let key = assignmentKey(in: line), Self.settingKeys.contains(key) else {
                continue
            }
            guard let assignmentSeparator = line.firstIndex(of: "=") else {
                continue
            }
            let rawValue = String(line[line.index(after: assignmentSeparator)...])
            guard let valueAndComment = splitShellValueAndComment(rawValue),
                  let value = decodeShellValue(valueAndComment.value) else {
                throw VPNSettingsStoreError.invalidConfigurationValue(key)
            }
            valuesByKey[key] = value
        }

        return VPNSettings(
            serverURL: valuesByKey["OPENCONNECT_URL", default: ""],
            username: valuesByKey["OPENCONNECT_USER", default: ""],
            rsaPIN: valuesByKey["OPENCONNECT_RSA_PIN", default: ""],
            certificateSHA1: valuesByKey["OPENCONNECT_CERTIFICATE_SHA1", default: ""],
            serverCertificatePin: valuesByKey["OPENCONNECT_SERVER_CERTIFICATE_PIN", default: ""]
        )
    }

    func save(_ settings: VPNSettings) throws -> VPNSettings {
        let normalizedSettings = try settings.validated()
        let configurationFileExists = try verifyConfigurationFileSafety()
        let currentContent = configurationFileExists
            ? try String(contentsOf: configurationFileURL, encoding: .utf8)
            : ""
        let valuesByKey = [
            "OPENCONNECT_URL": normalizedSettings.serverURL,
            "OPENCONNECT_USER": normalizedSettings.username,
            "OPENCONNECT_RSA_PIN": normalizedSettings.rsaPIN,
            "OPENCONNECT_CERTIFICATE_SHA1": normalizedSettings.certificateSHA1,
            "OPENCONNECT_SERVER_CERTIFICATE_PIN": normalizedSettings.serverCertificatePin,
        ]

        var outputLines: [String] = []
        var replacedKeys = Set<String>()
        var currentLines = currentContent.components(separatedBy: .newlines)
        while currentLines.last == "" {
            currentLines.removeLast()
        }
        for line in currentLines {
            guard let key = assignmentKey(in: line), Self.settingKeys.contains(key) else {
                outputLines.append(line)
                continue
            }
            guard !replacedKeys.contains(key), let value = valuesByKey[key] else {
                continue
            }
            guard let assignmentSeparator = line.firstIndex(of: "="),
                  let valueAndComment = splitShellValueAndComment(
                      String(line[line.index(after: assignmentSeparator)...])
                  ) else {
                throw VPNSettingsStoreError.invalidConfigurationValue(key)
            }
            outputLines.append(
                "\(key)=\(encodeShellValue(value))\(valueAndComment.commentSuffix)"
            )
            replacedKeys.insert(key)
        }
        for key in Self.settingKeys where !replacedKeys.contains(key) {
            outputLines.append("\(key)=\(encodeShellValue(valuesByKey[key, default: ""]))")
        }

        let updatedContent = outputLines.joined(separator: "\n") + "\n"
        try replaceConfigurationFile(with: Data(updatedContent.utf8))
        return normalizedSettings
    }

    private func verifyConfigurationFileSafety() throws -> Bool {
        var fileInformation = stat()
        let result = configurationFileURL.path.withCString {
            lstat($0, &fileInformation)
        }
        if result == 0 {
            let fileType = fileInformation.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw VPNSettingsStoreError.unsafeConfigurationFile
            }
            guard fileType == S_IFREG else {
                throw VPNSettingsStoreError.unsupportedConfigurationFile
            }
            return true
        }
        guard errno == ENOENT else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
        return false
    }

    private func assignmentKey(in line: String) -> String? {
        var assignment = line.trimmingCharacters(in: .whitespaces)
        guard !assignment.isEmpty, !assignment.hasPrefix("#") else {
            return nil
        }
        if assignment.hasPrefix("export ") {
            assignment = String(assignment.dropFirst("export ".count))
        }
        guard let assignmentSeparator = assignment.firstIndex(of: "=") else {
            return nil
        }
        let key = assignment[..<assignmentSeparator].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private func encodeShellValue(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func decodeShellValue(_ rawValue: String) -> String? {
        enum QuoteState {
            case unquoted
            case singleQuoted
            case doubleQuoted
        }

        let characters = Array(rawValue)
        var decodedValue = ""
        var quoteState = QuoteState.unquoted
        var characterIndex = 0

        // Supports plain values and shell quoting emitted by encodeShellValue without executing .env.
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
                } else if character == "$" || character == "`" || character.isWhitespace {
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

    private func splitShellValueAndComment(
        _ rawValue: String
    ) -> (value: String, commentSuffix: String)? {
        enum QuoteState {
            case unquoted
            case singleQuoted
            case doubleQuoted
        }

        let characters = Array(rawValue)
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
                } else if character.isWhitespace {
                    let suffixStartIndex = characterIndex
                    while characterIndex < characters.count,
                          characters[characterIndex].isWhitespace {
                        characterIndex += 1
                    }
                    if characterIndex == characters.count {
                        return (
                            value: String(characters[..<suffixStartIndex]),
                            commentSuffix: ""
                        )
                    }
                    guard characters[characterIndex] == "#" else {
                        return nil
                    }
                    return (
                        value: String(characters[..<suffixStartIndex]),
                        commentSuffix: String(characters[suffixStartIndex...])
                    )
                }
            case .singleQuoted:
                if character == "'" {
                    quoteState = .unquoted
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
                        characterIndex = nextCharacterIndex
                    }
                }
            }
            characterIndex += 1
        }
        guard quoteState == .unquoted else {
            return nil
        }
        return (value: rawValue, commentSuffix: "")
    }

    private func replaceConfigurationFile(with data: Data) throws {
        let temporaryFileURL = configurationFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".env.\(UUID().uuidString)", isDirectory: false)
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
        guard fchmod(temporaryFileDescriptor, mode_t(0o600)) == 0 else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
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
            configurationFileURL.path.withCString { configurationPath in
                Darwin.rename(temporaryPath, configurationPath)
            }
        }
        guard renameResult == 0 else {
            throw VPNSettingsStoreError.fileOperationFailed(String(cString: strerror(errno)))
        }
    }
}
