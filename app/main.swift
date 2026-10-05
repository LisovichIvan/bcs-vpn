import AppKit
import Darwin
import Foundation

private struct Configuration {
    let resourceDirectory: URL
    let dataDirectory: URL

    static func parse(arguments: [String]) -> Configuration {
        var projectDirectoryPath: String?
        var argumentIndex = 1

        while argumentIndex < arguments.count {
            if arguments[argumentIndex].hasPrefix("-psn_") {
                argumentIndex += 1
                continue
            }
            guard argumentIndex + 1 < arguments.count else {
                fatalError("Missing value for \(arguments[argumentIndex])")
            }

            switch arguments[argumentIndex] {
            case "--project-directory":
                projectDirectoryPath = arguments[argumentIndex + 1]
            default:
                fatalError("Unknown argument: \(arguments[argumentIndex])")
            }

            argumentIndex += 2
        }

        let resourceDirectory: URL
        if let projectDirectoryPath {
            resourceDirectory = URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
        } else {
            guard let bundledResourceDirectory = Bundle.main.resourceURL else {
                fatalError("Missing application Resources directory")
            }
            resourceDirectory = bundledResourceDirectory
        }
        let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BCS VPN", isDirectory: true)
        return Configuration(resourceDirectory: resourceDirectory, dataDirectory: dataDirectory)
    }
}

private enum ConnectionStatus {
    case checking
    case disconnected
    case connecting
    case disconnecting
    case connected
    case failed
    case unavailable

    var title: String {
        switch self {
        case .checking:
            return "Статус: проверка"
        case .disconnected:
            return "Статус: отключён"
        case .connecting:
            return "Статус: подключение"
        case .disconnecting:
            return "Статус: отключение"
        case .connected:
            return "Статус: подключён"
        case .failed:
            return "Статус: ошибка VPN"
        case .unavailable:
            return "Статус: runtime недоступен"
        }
    }

    var symbolName: String {
        switch self {
        case .checking, .disconnected, .connecting, .disconnecting, .connected:
            return "lock.shield"
        case .failed, .unavailable:
            return "exclamationmark.shield"
        }
    }

    var symbolColor: NSColor {
        switch self {
        case .checking:
            return .secondaryLabelColor
        case .disconnected:
            return .secondaryLabelColor
        case .connecting, .disconnecting:
            return .systemOrange
        case .connected:
            return .systemGreen
        case .failed, .unavailable:
            return .systemRed
        }
    }
}

private final class MenuBarController: NSObject, NSApplicationDelegate {
    private static let maximumCommandLogBytes: UInt64 = 256 * 1_024

    private let configuration: Configuration
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "Статус: проверка", action: nil, keyEquivalent: "")
    private let sessionTimeMenuItem = NSMenuItem(title: "До отключения: время неизвестно", action: nil, keyEquivalent: "")
    private let connectMenuItem = NSMenuItem(title: "Подключить", action: #selector(connect), keyEquivalent: "")
    private let disconnectMenuItem = NSMenuItem(title: "Отключить", action: #selector(disconnect), keyEquivalent: "")
    private let okdStatusMenuItem = NSMenuItem(title: "OKD: отключён", action: nil, keyEquivalent: "")
    private let okdConnectMenuItem = NSMenuItem(title: "Подключить OKD Proxy", action: #selector(connectOKD), keyEquivalent: "")
    private let okdDisconnectMenuItem = NSMenuItem(title: "Отключить OKD Proxy", action: #selector(disconnectOKD), keyEquivalent: "")
    private let okdSettingsMenuItem = NSMenuItem(
        title: "Настройки OKD Proxy…",
        action: #selector(openOKDSettings),
        keyEquivalent: ""
    )
    private let settingsMenuItem = NSMenuItem(
        title: "Настройки…",
        action: #selector(openSettings),
        keyEquivalent: ","
    )
    private let logsMenuItem = NSMenuItem(
        title: "Журналы…",
        action: #selector(openLogs),
        keyEquivalent: ""
    )
    private let fallbackProxyServer = FallbackProxyServer()
    private lazy var okdProxyManager = OKDProxyManager(
        resourceDirectory: configuration.resourceDirectory,
        dataDirectory: configuration.dataDirectory
    )
    private lazy var okdSettingsWindowController = OKDProxySettingsWindowController(
        dataDirectory: configuration.dataDirectory
    )
    private lazy var settingsWindowController = SettingsWindowController(
        projectDirectory: configuration.dataDirectory
    )
    private var activeCommand: Process?
    private var fallbackProxyFailure: String?
    private var statusCheckInProgress = false
    private var statusTimer: Timer?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        okdProxyManager.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLogger.info("application.launch begin resourceDirectory=\(configuration.resourceDirectory.path) dataDirectory=\(configuration.dataDirectory.path)")
        NSApplication.shared.setActivationPolicy(.accessory)
        configureMenu()
        do {
            try fallbackProxyServer.start()
        } catch {
            fallbackProxyFailure = error.localizedDescription
            DiagnosticLogger.error("fallback.start failed error=\(error.localizedDescription)")
            applyStatus(.failed)
            showError(title: "Не удалось запустить fallback SOCKS5", details: error.localizedDescription)
        }
        DiagnosticLogger.info("application.launch fallbackReady=\(fallbackProxyFailure == nil)")
        refreshStatus()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatus()
            self?.refreshOKDStatus()
        }
        // Keep the status and countdown current while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        connectMenuItem.target = self
        disconnectMenuItem.target = self
        okdConnectMenuItem.target = self
        okdDisconnectMenuItem.target = self
        okdSettingsMenuItem.target = self
        settingsMenuItem.target = self
        logsMenuItem.target = self

        menu.addItem(statusMenuItem)
        sessionTimeMenuItem.isEnabled = false
        menu.addItem(sessionTimeMenuItem)
        menu.addItem(.separator())
        menu.addItem(connectMenuItem)
        menu.addItem(disconnectMenuItem)
        menu.addItem(.separator())
        okdStatusMenuItem.isEnabled = false
        menu.addItem(okdStatusMenuItem)
        menu.addItem(okdConnectMenuItem)
        menu.addItem(okdDisconnectMenuItem)
        menu.addItem(okdSettingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(settingsMenuItem)
        menu.addItem(logsMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выйти",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        applyStatus(.checking)
        applyOKDStatus(.stopped)
    }

    @objc private func connect() {
        DiagnosticLogger.info("menu.connect requested")
        runCommand(scriptName: "connect.sh", progressStatus: .connecting)
    }

    @objc private func disconnect() {
        DiagnosticLogger.info("menu.disconnect requested")
        runCommand(scriptName: "disconnect.sh", progressStatus: .disconnecting)
    }

    @objc private func connectOKD() {
        DiagnosticLogger.info("menu.okd.connect requested")
        do {
            try okdProxyManager.start()
            applyOKDStatus(okdProxyManager.status)
        } catch {
            okdProxyManager.stop()
            applyOKDStatus(.failed)
            showError(title: "Не удалось запустить OKD Proxy", details: error.localizedDescription)
        }
    }

    @objc private func disconnectOKD() {
        DiagnosticLogger.info("menu.okd.disconnect requested")
        okdProxyManager.stop()
        applyOKDStatus(okdProxyManager.status)
    }

    @objc private func openOKDSettings() {
        DiagnosticLogger.info("menu.okd.settings requested")
        okdSettingsWindowController.open()
    }

    @objc private func openSettings() {
        DiagnosticLogger.info("menu.settings requested")
        settingsWindowController.open()
    }

    @objc private func openLogs() {
        DiagnosticLogger.info("menu.logs requested")
        settingsWindowController.openLogs()
    }

    private func runCommand(scriptName: String, progressStatus: ConnectionStatus) {
        guard activeCommand == nil else {
            return
        }

        applyStatus(progressStatus)
        connectMenuItem.isEnabled = false
        disconnectMenuItem.isEnabled = false

        let process = Process()
        let scriptURL = configuration.resourceDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(scriptName)
        // Launch bash explicitly. Process.run() can report ENOENT when a
        // bundled script is launched directly through its env-based shebang.
        process.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = configuration.resourceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["BCS_VPN_DATA_DIRECTORY"] = configuration.dataDirectory.path
        environment["BCS_VPN_APP_BUNDLE"] = Bundle.main.bundlePath
        process.environment = environment

        let logFile = configuration.dataDirectory
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("menu-bar.log")

        do {
            let logHandle = try openCommandLog(at: logFile)
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] completedProcess in
                try? logHandle.close()
                DiagnosticLogger.info("command.complete script=\(scriptName) status=\(completedProcess.terminationStatus)")
                let output = (try? Self.readCommandLogTail(at: logFile)) ?? ""
                DispatchQueue.main.async {
                    self?.commandDidFinish(exitCode: completedProcess.terminationStatus, output: output)
                }
            }

            activeCommand = process
            try process.run()
        } catch {
            DiagnosticLogger.error("command.start failed script=\(scriptName) error=\(error.localizedDescription)")
            activeCommand = nil
            applyStatus(.unavailable)
            showError(title: "Не удалось запустить команду", details: error.localizedDescription)
        }
    }

    private func openCommandLog(at fileURL: URL) throws -> FileHandle {
        // The installed app keeps runtime data under Application Support;
        // unlike the source checkout, its run directory may not exist yet.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let openFlags = O_WRONLY | O_APPEND | O_NONBLOCK | O_NOFOLLOW
        var fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, openFlags)
        }
        if fileDescriptor < 0 && errno == ENOENT {
            fileDescriptor = fileURL.path.withCString {
                Darwin.open($0, openFlags | O_CREAT | O_EXCL, mode_t(0o600))
            }
        }
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0,
              fileInformation.st_mode & S_IFMT == S_IFREG,
              fchmod(fileDescriptor, mode_t(0o600)) == 0,
              ftruncate(fileDescriptor, 0) == 0 else {
            let errorNumber = errno == 0 ? EINVAL : errno
            Darwin.close(fileDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }

        let fileStatusFlags = fcntl(fileDescriptor, F_GETFL)
        guard fileStatusFlags >= 0,
              fcntl(
                  fileDescriptor,
                  F_SETFL,
                  (fileStatusFlags | O_APPEND) & ~O_NONBLOCK
              ) == 0 else {
            let errorNumber = errno
            Darwin.close(fileDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }

    private static func readCommandLogTail(at fileURL: URL) throws -> String {
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0,
              fileInformation.st_mode & S_IFMT == S_IFREG else {
            let errorNumber = errno == 0 ? EINVAL : errno
            Darwin.close(fileDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
        }

        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        let fileSize = try fileHandle.seekToEnd()
        let firstDisplayedByte = fileSize > maximumCommandLogBytes
            ? fileSize - maximumCommandLogBytes
            : 0
        try fileHandle.seek(toOffset: firstDisplayedByte)
        let data = try fileHandle.read(upToCount: Int(maximumCommandLogBytes)) ?? Data()
        let content = String(decoding: data, as: UTF8.self)
        return firstDisplayedByte == 0
            ? content
            : "[Показаны последние 256 КБ журнала]\n" + content
    }

    private func commandDidFinish(exitCode: Int32, output: String) {
        activeCommand = nil
        refreshStatus()

        guard exitCode != 0 else {
            return
        }

        let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
        showError(
            title: "Команда VPN завершилась с ошибкой",
            details: details.isEmpty ? "Код завершения: \(exitCode)" : details
        )
    }

    private func refreshOKDStatus() {
        okdProxyManager.refreshStatus()
        applyOKDStatus(okdProxyManager.status)
    }

    private func applyOKDStatus(_ status: OKDProxyStatus) {
        okdStatusMenuItem.title = status.title
        okdConnectMenuItem.isEnabled = status == .stopped || status == .failed
        okdDisconnectMenuItem.isEnabled = status == .starting || status == .connected || status == .stopping || status == .failed
    }

    private func refreshStatus() {
        guard activeCommand == nil, !statusCheckInProgress else {
            return
        }
        guard fallbackProxyFailure == nil else {
            applyStatus(.failed)
            return
        }

        statusCheckInProgress = true
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let statusScriptURL = configuration.resourceDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("status.sh")
        process.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        process.arguments = [statusScriptURL.path]
        process.currentDirectoryURL = configuration.resourceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["BCS_VPN_DATA_DIRECTORY"] = configuration.dataDirectory.path
        environment["BCS_VPN_APP_BUNDLE"] = Bundle.main.bundlePath
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] completedProcess in
            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = String(decoding: errorData, as: UTF8.self)

            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.statusCheckInProgress = false
                guard self.activeCommand == nil else {
                    return
                }
                self.applyStatus(self.statusFromScript(
                    exitCode: completedProcess.terminationStatus,
                    output: output,
                    errorOutput: errorOutput
                ))
            }
        }

        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            statusCheckInProgress = false
            applyStatus(.unavailable)
        }
    }

    private func statusFromScript(exitCode: Int32, output: String, errorOutput: String) -> ConnectionStatus {
        if exitCode != 0 {
            return .unavailable
        }

        switch output {
        case "connected":
            return .connected
        case "connecting":
            return .connecting
        case "disconnected":
            return .disconnected
        case "failed":
            return .failed
        default:
            return .unavailable
        }
    }

    private func applyStatus(_ status: ConnectionStatus) {
        let expirationFile = configuration.dataDirectory
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("vpn-session-expiration")
        let expiration = status == .connected
            ? try? VPNSessionTime.readExpiration(at: expirationFile)
            : nil
        let sessionTime = expiration.map { VPNSessionTime.display(expiration: $0, now: Date()) }
        sessionTimeMenuItem.isHidden = status != .connected
        sessionTimeMenuItem.title = sessionTime?.menuTitle ?? "До отключения: время неизвестно"
        statusMenuItem.title = status.title
        connectMenuItem.isEnabled = activeCommand == nil && (status == .disconnected || status == .failed)
        disconnectMenuItem.isEnabled = activeCommand == nil && (
            status == .connected || status == .connecting || status == .failed
        )

        if let button = statusItem.button {
            let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [status.symbolColor])
            let symbolConfiguration = sizeConfiguration.applying(colorConfiguration)
            let image = NSImage(
                systemSymbolName: status.symbolName,
                accessibilityDescription: status.title
            )?.withSymbolConfiguration(symbolConfiguration)
            image?.isTemplate = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = sessionTime.map { " \($0.countdown)" } ?? (image == nil ? "VPN" : "")
            var toolTip = "BCS VPN: \(status.title.replacingOccurrences(of: "Статус: ", with: ""))"
            if status == .connected {
                toolTip += "\n\(sessionTimeMenuItem.title)"
                if let expiration {
                    toolTip += "\nОкончание сессии: \(DateFormatter.localizedString(from: expiration, dateStyle: .short, timeStyle: .medium))"
                }
            }
            button.toolTip = toolTip
        }
    }

    private func showError(title: String, details: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.runModal()
    }
}

private let configuration = Configuration.parse(arguments: CommandLine.arguments)
private let menuBarController = MenuBarController(configuration: configuration)
private let application = NSApplication.shared
application.delegate = menuBarController
application.run()
