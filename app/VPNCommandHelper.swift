import Darwin
import CryptoKit
import Foundation
import Security

private enum VPNCommandHelperError: LocalizedError {
    case invalidArguments
    case invalidInput(String)
    case fileOperationFailed(String)
    case commandFailed(String)
    case securityOperationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Некорректные аргументы bcs-vpn-helper."
        case let .invalidInput(details):
            return details
        case let .fileOperationFailed(details):
            return "Ошибка файла: \(details)"
        case let .commandFailed(command):
            return "Команда \(command) завершилась с ошибкой."
        case let .securityOperationFailed(operation, status):
            let details = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Ошибка Security при операции \(operation): \(details)."
        }
    }
}

@main
private enum VPNCommandHelper {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw VPNCommandHelperError.invalidArguments
        }

        switch command {
        case "read-settings":
            guard arguments.count == 2 else {
                throw VPNCommandHelperError.invalidArguments
            }
            try printSettings(projectDirectoryPath: arguments[1])
        case "set-rsa-pin":
            guard arguments.count == 2 else {
                throw VPNCommandHelperError.invalidArguments
            }
            try setRSAPIN(projectDirectoryPath: arguments[1])
        case "migrate-settings":
            guard arguments.count == 2 else {
                throw VPNCommandHelperError.invalidArguments
            }
            _ = try settingsStore(projectDirectoryPath: arguments[1]).load()
        case "export-identity":
            guard arguments.count == 4 else {
                throw VPNCommandHelperError.invalidArguments
            }
            try exportIdentity(
                requestedSHA1: arguments[1],
                outputPath: arguments[2],
                passwordFilePath: arguments[3]
            )
#if CERTIFICATE_SELECTION_TESTS
        case "convert-pkcs12":
            guard arguments.count == 4 else {
                throw VPNCommandHelperError.invalidArguments
            }
            let pkcs12Data = try readSecureRegularFile(
                at: URL(fileURLWithPath: arguments[1], isDirectory: false)
            )
            try writeConvertedIdentity(
                pkcs12Data: pkcs12Data,
                outputPath: arguments[2],
                passwordFilePath: arguments[3]
            )
#endif
        case "exec-with-default-signals":
            guard arguments.count >= 2 else {
                throw VPNCommandHelperError.invalidArguments
            }
            try executeWithDefaultSignals(arguments: Array(arguments.dropFirst()))
        default:
            throw VPNCommandHelperError.invalidArguments
        }
    }

    private static func settingsStore(projectDirectoryPath: String) -> VPNSettingsStore {
        VPNSettingsStore(projectDirectory: URL(
            fileURLWithPath: projectDirectoryPath,
            isDirectory: true
        ))
    }

    private static func printSettings(projectDirectoryPath: String) throws {
        let settings = try settingsStore(projectDirectoryPath: projectDirectoryPath).load()
        let lines = [
            "OPENCONNECT_URL\t\(settings.serverURL)",
            "OPENCONNECT_USER\t\(settings.username)",
            "OPENCONNECT_RSA_PIN\t\(settings.rsaPIN)",
            "OPENCONNECT_CERTIFICATE_SHA1\t\(settings.certificateSHA1)",
            "OPENCONNECT_SERVER_CERTIFICATE_PIN\t\(settings.serverCertificatePin)",
        ]
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func setRSAPIN(projectDirectoryPath: String) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let rsaPIN = String(data: input, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rsaPIN.isEmpty else {
            throw VPNCommandHelperError.invalidInput("Постоянный PIN не задан.")
        }

        let store = settingsStore(projectDirectoryPath: projectDirectoryPath)
        let settings = try store.load()
        _ = try store.save(VPNSettings(
            serverURL: settings.serverURL,
            username: settings.username,
            rsaPIN: rsaPIN,
            certificateSHA1: settings.certificateSHA1,
            serverCertificatePin: settings.serverCertificatePin
        ))
    }

    private static func exportIdentity(
        requestedSHA1: String,
        outputPath: String,
        passwordFilePath: String
    ) throws {
        let normalizedRequestedSHA1 = requestedSHA1
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalizedRequestedSHA1.count == 40,
              normalizedRequestedSHA1.allSatisfy(\.isHexDigit) else {
            throw VPNCommandHelperError.invalidInput("SHA-1 сертификата должен содержать 40 шестнадцатеричных символов.")
        }

        let passwordData = try readSecureRegularFile(
            at: URL(fileURLWithPath: passwordFilePath, isDirectory: false)
        )
        guard let password = String(data: passwordData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else {
            throw VPNCommandHelperError.invalidInput("Пароль экспорта сертификата не задан.")
        }

        let identity = try identity(matchingSHA1: normalizedRequestedSHA1)
        let pkcs12Data = try exportPKCS12(identity: identity, password: password)
        try writeConvertedIdentity(
            pkcs12Data: pkcs12Data,
            outputPath: outputPath,
            passwordFilePath: passwordFilePath
        )
    }

    private static func identity(matchingSHA1 requestedSHA1: String) throws -> SecIdentity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw VPNCommandHelperError.invalidInput(
                "Сертификат \(requestedSHA1) не найден в Keychain."
            )
        }
        guard status == errSecSuccess else {
            throw VPNCommandHelperError.securityOperationFailed("получение списка сертификатов", status)
        }
        guard let certificates = result as? [SecCertificate] else {
            throw VPNCommandHelperError.invalidInput("Security вернул некорректный список сертификатов.")
        }

        for certificate in certificates {
            let fingerprint = Insecure.SHA1.hash(
                data: SecCertificateCopyData(certificate) as Data
            ).map { String(format: "%02X", $0) }.joined()
            if fingerprint == requestedSHA1 {
                var selectedIdentity: SecIdentity?
                let identityStatus = SecIdentityCreateWithCertificate(
                    nil,
                    certificate,
                    &selectedIdentity
                )
                guard identityStatus == errSecSuccess, let selectedIdentity else {
                    throw VPNCommandHelperError.securityOperationFailed(
                        "получение SecIdentity выбранного сертификата",
                        identityStatus
                    )
                }
                return selectedIdentity
            }
        }

        throw VPNCommandHelperError.invalidInput(
            "Сертификат \(requestedSHA1) не найден в Keychain."
        )
    }

    private static func exportPKCS12(identity: SecIdentity, password: String) throws -> Data {
        let passwordReference = password as CFString
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.passphrase = Unmanaged.passUnretained(passwordReference)
        var exportedData: CFData?
        let status = SecItemExport(
            identity,
            .formatPKCS12,
            SecItemImportExportFlags(),
            &parameters,
            &exportedData
        )
        guard status == errSecSuccess else {
            throw VPNCommandHelperError.securityOperationFailed("экспорт identity", status)
        }
        guard let exportedData else {
            throw VPNCommandHelperError.invalidInput("Security не вернул данные PKCS#12.")
        }
        return exportedData as Data
    }

    private static func writeConvertedIdentity(
        pkcs12Data: Data,
        outputPath: String,
        passwordFilePath: String
    ) throws {
        let outputData = try runOpenSSL(
            arguments: ["pkcs12", "-nodes", "-passin", "file:\(passwordFilePath)"],
            input: pkcs12Data
        )
        try replaceSecureFile(
            at: URL(fileURLWithPath: outputPath, isDirectory: false),
            with: outputData
        )
    }

    private static func runOpenSSL(arguments: [String], input: Data) throws -> Data {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl", isDirectory: false)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        let output = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPNCommandHelperError.commandFailed("/usr/bin/openssl \(arguments.first ?? "")")
        }
        return output
    }

    private static func readSecureRegularFile(at fileURL: URL) throws -> Data {
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else {
            throw VPNCommandHelperError.fileOperationFailed(String(cString: strerror(errno)))
        }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0,
              fileInformation.st_mode & S_IFMT == S_IFREG,
              fileInformation.st_uid == geteuid(),
              fileInformation.st_mode & mode_t(0o077) == 0 else {
            Darwin.close(fileDescriptor)
            throw VPNCommandHelperError.invalidInput(
                "Файл \(fileURL.lastPathComponent) должен принадлежать текущему пользователю и иметь права 600."
            )
        }

        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        return try fileHandle.readToEnd() ?? Data()
    }

    private static func replaceSecureFile(at fileURL: URL, with data: Data) throws {
        let temporaryFileURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

        var fileDescriptor = temporaryFileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard fileDescriptor >= 0 else {
            throw VPNCommandHelperError.fileOperationFailed(String(cString: strerror(errno)))
        }
        defer {
            if fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
            }
        }

        let writeSucceeded = data.withUnsafeBytes { buffer -> Bool in
            var writtenByteCount = 0
            while writtenByteCount < buffer.count {
                let currentWriteCount = Darwin.write(
                    fileDescriptor,
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
        guard writeSucceeded, fsync(fileDescriptor) == 0 else {
            throw VPNCommandHelperError.fileOperationFailed(String(cString: strerror(errno)))
        }
        guard Darwin.close(fileDescriptor) == 0 else {
            fileDescriptor = -1
            throw VPNCommandHelperError.fileOperationFailed(String(cString: strerror(errno)))
        }
        fileDescriptor = -1
        guard Darwin.rename(temporaryFileURL.path, fileURL.path) == 0 else {
            throw VPNCommandHelperError.fileOperationFailed(String(cString: strerror(errno)))
        }
    }

    private static func executeWithDefaultSignals(arguments: [String]) throws {
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)

        var duplicatedArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        duplicatedArguments.append(nil)
        defer {
            for argument in duplicatedArguments.compactMap({ $0 }) {
                free(argument)
            }
        }

        let executionResult = duplicatedArguments.withUnsafeMutableBufferPointer { buffer in
            Darwin.execvp(buffer[0], buffer.baseAddress)
        }
        guard executionResult == 0 else {
            throw VPNCommandHelperError.commandFailed(arguments[0])
        }
    }
}
