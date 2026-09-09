import Darwin
import Foundation

@main
private enum VPNSettingsStoreTests {
    static func main() throws {
        let projectDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let testRootDirectory = projectDirectory
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("settings-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testRootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: testRootDirectory) }

        try testSaveAndLoad(in: testRootDirectory.appendingPathComponent("save", isDirectory: true))
        try testPortableExportAndImport(
            in: testRootDirectory.appendingPathComponent("portable", isDirectory: true)
        )
        try testLegacyMigration(
            in: testRootDirectory.appendingPathComponent("migration", isDirectory: true)
        )
        try testSymbolicLinkRejection(
            in: testRootDirectory.appendingPathComponent("symbolic-link", isDirectory: true)
        )
        try testInvalidServerCertificatePin()
        print("VPNSettingsStore: сохранение, миграция и проверки безопасности работают.")
    }

    private static func makeValidSettings(
        username: String = "test-user",
        rsaPIN: String = "1234"
    ) -> VPNSettings {
        let digest = Data((0..<32).map(UInt8.init)).base64EncodedString()
        return VPNSettings(
            serverURL: "https://fw2.bcs.ru",
            username: username,
            rsaPIN: rsaPIN,
            certificateSHA1: String(repeating: "A", count: 40),
            serverCertificatePin: "pin-sha256:\(digest)"
        )
    }

    private static func createTestDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    private static func testSaveAndLoad(in directory: URL) throws {
        try createTestDirectory(directory)
        let store = VPNSettingsStore(projectDirectory: directory)
        let expectedSettings = makeValidSettings()
        let savedSettings = try store.save(expectedSettings)
        guard savedSettings == expectedSettings, try store.load() == expectedSettings else {
            throw TestError.failed("Сохранённые настройки отличаются от загруженных.")
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.configurationFileURL.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard permissions == 0o600 else {
            throw TestError.failed("Файл настроек создан с правами \(permissions ?? -1).")
        }
    }

    private static func testPortableExportAndImport(in directory: URL) throws {
        try createTestDirectory(directory)
        let store = VPNSettingsStore(projectDirectory: directory)
        let exportedFileURL = directory.appendingPathComponent("profile.plist", isDirectory: false)
        let expectedSettings = makeValidSettings(username: "portable-user")
        try store.export(expectedSettings, to: exportedFileURL)

        let importedSettings = try store.load(from: exportedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: exportedFileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard importedSettings == expectedSettings, permissions == 0o600 else {
            throw TestError.failed("Переносимый профиль настроек импортирован некорректно.")
        }
    }

    private static func testLegacyMigration(in directory: URL) throws {
        try createTestDirectory(directory)
        let settings = makeValidSettings(username: #"DOMAIN\user#name"#)
        let legacyContent = """
        OPENCONNECT_URL='fw2.bcs.ru'
        OPENCONNECT_USER="DOMAIN\\user#name"
        OPENCONNECT_RSA_PIN='\(settings.rsaPIN)'
        OPENCONNECT_CERTIFICATE_SHA1='\(settings.certificateSHA1)'
        OPENCONNECT_SERVER_CERTIFICATE_PIN='\(settings.serverCertificatePin)'
        """
        let legacyFileURL = directory.appendingPathComponent(".env", isDirectory: false)
        try Data(legacyContent.utf8).write(to: legacyFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: legacyFileURL.path
        )

        let store = VPNSettingsStore(projectDirectory: directory)
        guard try store.load() == settings,
              FileManager.default.fileExists(atPath: store.configurationFileURL.path) else {
            throw TestError.failed("Старый .env не мигрирован в Property List.")
        }
    }

    private static func testSymbolicLinkRejection(in directory: URL) throws {
        try createTestDirectory(directory)
        let targetFileURL = directory.appendingPathComponent("target.plist", isDirectory: false)
        try Data().write(to: targetFileURL)
        let configurationFileURL = directory.appendingPathComponent(
            "vpn-settings.plist",
            isDirectory: false
        )
        try FileManager.default.createSymbolicLink(
            at: configurationFileURL,
            withDestinationURL: targetFileURL
        )

        do {
            _ = try VPNSettingsStore(projectDirectory: directory).load()
            throw TestError.failed("Символическая ссылка принята как файл настроек.")
        } catch is VPNSettingsStoreError {
            return
        }
    }

    private static func testInvalidServerCertificatePin() throws {
        let settings = VPNSettings(
            serverURL: "https://fw2.bcs.ru",
            username: "test-user",
            rsaPIN: "1234",
            certificateSHA1: String(repeating: "A", count: 40),
            serverCertificatePin: "pin-sha256:x"
        )
        do {
            _ = try settings.validated()
            throw TestError.failed("Короткое закрепление сертификата принято как корректное.")
        } catch is VPNSettingsStoreError {
            return
        }
    }
}

private enum TestError: Error {
    case failed(String)
}
