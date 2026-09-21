import AppKit
import Foundation

// The manager owns one long-running oc port-forward process. Credentials are
// passed through a temporary 0600 plist, never as command-line arguments.
enum OKDProxyStatus: Equatable {
    case unavailable
    case stopped
    case starting
    case connected
    case stopping
    case failed

    var title: String {
        switch self {
        case .unavailable: return "OKD: недоступен"
        case .stopped: return "OKD: отключён"
        case .starting: return "OKD: подключение"
        case .connected: return "OKD: подключён"
        case .stopping: return "OKD: отключение"
        case .failed: return "OKD: ошибка"
        }
    }
}

final class OKDProxyManager {
    private let resourceDirectory: URL
    private let dataDirectory: URL
    private let settingsStore: OKDProxySettingsStore
    private var process: Process?
    private var logHandle: FileHandle?
    private var runtimeConfigurationURL: URL?
    private(set) var status: OKDProxyStatus = .stopped
    private var stopping = false

    init(resourceDirectory: URL, dataDirectory: URL) {
        self.resourceDirectory = resourceDirectory
        self.dataDirectory = dataDirectory
        settingsStore = OKDProxySettingsStore(dataDirectory: dataDirectory)
        let runDirectory = dataDirectory.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("okd-proxy-runtime.plist"))
        try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("okd-proxy-kubeconfig"))
    }

    deinit {
        process?.terminate()
        try? logHandle?.close()
        cleanupRuntimeConfiguration()
    }

    func start() throws {
        guard process == nil else { return }
        let settings = try settingsStore.load().validated()
        guard let scriptURL = scriptURL else {
            throw NSError(domain: "BCSVPN.OKD", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден скрипт OKD Proxy."])
        }
        guard FileManager.default.isExecutableFile(atPath: findOCPath() ?? "") else {
            throw NSError(domain: "BCSVPN.OKD", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не найден oc. Установите OpenShift CLI и добавьте его в PATH."])
        }

        let runDirectory = dataDirectory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let configURL = runDirectory.appendingPathComponent("okd-proxy-runtime.plist", isDirectory: false)
        if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let configData = try encoder.encode(settings)
        guard FileManager.default.createFile(atPath: configURL.path, contents: configData, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "BCSVPN.OKD", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать временную конфигурацию OKD."])
        }
        runtimeConfigurationURL = configURL

        let logURL = runDirectory.appendingPathComponent("okd-proxy.log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            cleanupRuntimeConfiguration()
            throw NSError(domain: "BCSVPN.OKD", code: 4, userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть журнал OKD Proxy."])
        }
        try logHandle.truncate(atOffset: 0)
        try logHandle.seekToEnd()

        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        command.arguments = [scriptURL.path, configURL.path]
        command.currentDirectoryURL = resourceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["BCS_VPN_DATA_DIRECTORY"] = dataDirectory.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        command.environment = environment
        command.standardOutput = logHandle
        command.standardError = logHandle
        command.terminationHandler = { [weak self] completedProcess in
            try? logHandle.close()
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.logHandle = nil
                self.cleanupRuntimeConfiguration()
                let wasStopping = self.stopping
                self.stopping = false
                self.status = wasStopping || completedProcess.terminationStatus == 0 ? .stopped : .failed
                DiagnosticLogger.info("okd.proxy.complete status=\(completedProcess.terminationStatus) state=\(self.status.title)")
            }
        }

        process = command
        self.logHandle = logHandle
        stopping = false
        status = .starting
        do {
            try command.run()
            DiagnosticLogger.info("okd.proxy.start server=\(settings.serverURL) namespace=\(settings.namespace) selector=\(settings.podSelector)")
        } catch {
            process = nil
            self.logHandle = nil
            try? logHandle.close()
            cleanupRuntimeConfiguration()
            status = .failed
            throw error
        }
    }

    func stop() {
        guard let process else {
            status = .stopped
            cleanupRuntimeConfiguration()
            return
        }
        stopping = true
        status = .stopping
        process.terminate()
    }

    func refreshStatus() {
        guard let process else {
            if status != .failed { status = .stopped }
            return
        }
        guard process.isRunning else { return }
        let statusURL = dataDirectory.appendingPathComponent("run/okd-proxy.status")
        if let value = try? String(contentsOf: statusURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            switch value {
            case "connected": status = .connected
            case "starting": status = .starting
            case "stopping": status = .stopping
            default: break
            }
        }
    }

    private var scriptURL: URL? {
        let url = resourceDirectory.appendingPathComponent("scripts/okd-proxy.sh")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    private func findOCPath() -> String? {
        for path in ["/opt/homebrew/bin/oc", "/usr/local/bin/oc", "/usr/bin/oc"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func cleanupRuntimeConfiguration() {
        if let runtimeConfigurationURL {
            try? FileManager.default.removeItem(at: runtimeConfigurationURL)
        }
        self.runtimeConfigurationURL = nil
    }
}
