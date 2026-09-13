import Darwin
import Foundation

/// Lightweight diagnostic log for UI and lifecycle failures.
/// Never pass PINs, RSA codes, certificate contents, or full settings here.
enum DiagnosticLogger {
    private static let lock = NSLock()
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BCS VPN/bcs-vpn.log")

    static func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    static func warning(_ message: String) {
        append(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    private static func append(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = logURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level)] [pid=\(getpid())] \(message)\n"
            _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
            _ = fchmod(descriptor, 0o600)
        } catch {
            // Diagnostics must never crash or block the application.
        }
    }
}
