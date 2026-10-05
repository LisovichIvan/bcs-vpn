import Darwin
import Foundation

@main
private enum VPNSessionTimeTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 3)
        let testDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let proxyScript = URL(fileURLWithPath: CommandLine.arguments[2])
        let expirationFile = testDirectory.appendingPathComponent("vpn-session-expiration")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        precondition(VPNSessionTime.expiration(from: "1800003600\n") == now.addingTimeInterval(3600))
        for invalidContent in ["", "0", "-1", "1.5", "NaN", "1800003600 extra", "10000000000", "１２３"] {
            precondition(VPNSessionTime.expiration(from: invalidContent) == nil)
        }
        for (seconds, expected) in [(3600.0, "01:00"), (3599.0, "01:00"), (60.1, "00:02"),
                                    (60.0, "00:01"), (0.1, "00:01"), (0.0, "00:00"),
                                    (-60.0, "00:00"), (90_000.0, "25:00")] {
            let display = VPNSessionTime.display(expiration: now.addingTimeInterval(seconds), now: now)
            precondition(display.countdown == expected, "Неверный отсчёт для \(seconds): \(display.countdown)")
            precondition(display.menuTitle == (seconds <= 0 ? "Лимит сессии истёк" : "До отключения: \(expected)"))
        }
        let deadline = now.addingTimeInterval(3600)
        precondition(VPNSessionTime.display(expiration: deadline, now: now.addingTimeInterval(1800)).countdown == "00:30")
        precondition(VPNSessionTime.display(expiration: deadline, now: now.addingTimeInterval(7200)).countdown == "00:00")

        let runtimeDirectory = testDirectory.appendingPathComponent("runtime", isDirectory: true)
        let binaryDirectory = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let mockProxy = binaryDirectory.appendingPathComponent("ocproxy")
        try "#!/bin/bash\n[[ \"$*\" == '-D 8890 -k 30' ]]\n".write(to: mockProxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mockProxy.path)

        let timeoutOptions: [(String, Int?)] = [
            ("X-CSTP-Session-Timeout=3600\n", 3600),
            ("X-CSTP-Session-Timeout=7200\nX-CSTP-Session-Timeout-Remaining=1800\nX-CSTP-Lease-Duration=3600\n", 1800),
            ("X-CSTP-Session-Timeout-Remaining=1800\nX-CSTP-Session-Timeout=7200\n", 1800),
            ("X-CSTP-Session-Timeout=0\nX-CSTP-Lease-Duration=0000000120\n", 120),
            ("X-CSTP-Lease-Duration=60\n", 60),
            ("X-CSTP-Idle-Timeout=30\nX-CSTP-Rekey-Time=60\n", nil),
            ("X-CSTP-Session-Timeout=0\n", nil),
            ("X-CSTP-Session-Timeout=-1\nX-CSTP-Lease-Duration=2147483648\n", nil),
            ("X-CSTP-Session-Timeout=99999999999999999999\n", nil),
            ("X-CSTP-Session-Timeout=$(exit 99)\n", nil),
            ("X-CSTP-Session-Timeout=1.5\n", nil),
            ("", nil)
        ]
        for (options, expectedSeconds) in timeoutOptions {
            // Every launch must replace/remove data from the previous session.
            try "1800003600\n".write(to: expirationFile, atomically: true, encoding: .utf8)
            let beforeLaunch = Date().timeIntervalSince1970.rounded(.down)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [proxyScript.path]
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "BCS_VPN_RUNTIME_DIRECTORY": runtimeDirectory.path,
                "BCS_VPN_RUN_DIRECTORY": testDirectory.path,
                "CISCO_CSTP_OPTIONS": options
            ]
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Запуск тестового ocproxy завершился ошибкой")
            let afterLaunch = Date().timeIntervalSince1970.rounded(.down)
            if let expectedSeconds {
                guard let expiration = try VPNSessionTime.readExpiration(at: expirationFile) else {
                    preconditionFailure("Серверный лимит не сохранён")
                }
                precondition(expiration.timeIntervalSince1970 >= beforeLaunch + Double(expectedSeconds))
                precondition(expiration.timeIntervalSince1970 <= afterLaunch + Double(expectedSeconds))
                let attributes = try FileManager.default.attributesOfItem(atPath: expirationFile.path)
                precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            } else {
                precondition(!FileManager.default.fileExists(atPath: expirationFile.path), "Остался старый таймер")
            }
        }

        try "invalid".write(to: expirationFile, atomically: true, encoding: .utf8)
        let invalidExpiration = try VPNSessionTime.readExpiration(at: expirationFile)
        precondition(invalidExpiration == nil)
        try String(repeating: "1", count: 65).write(to: expirationFile, atomically: true, encoding: .utf8)
        let oversizedExpiration = try VPNSessionTime.readExpiration(at: expirationFile)
        precondition(oversizedExpiration == nil)
        try FileManager.default.removeItem(at: expirationFile)
        try FileManager.default.createSymbolicLink(at: expirationFile, withDestinationURL: mockProxy)
        do {
            _ = try VPNSessionTime.readExpiration(at: expirationFile)
            preconditionFailure("Символическая ссылка не должна читаться")
        } catch {}
        try FileManager.default.removeItem(at: expirationFile)
        precondition(mkfifo(expirationFile.path, mode_t(0o600)) == 0)
        let pipeExpiration = try VPNSessionTime.readExpiration(at: expirationFile)
        precondition(pipeExpiration == nil)
        try FileManager.default.removeItem(at: expirationFile)
        do {
            _ = try VPNSessionTime.readExpiration(at: expirationFile)
            preconditionFailure("Отсутствующий файл должен вернуть ошибку")
        } catch {}
        print("VPN session time: серверные лимиты, отсчёт, смена сессии и безопасное чтение проверены.")
    }
}
