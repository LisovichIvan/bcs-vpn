import AppKit
import Foundation

private struct Configuration {
    let projectDirectory: URL

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

        if let projectDirectoryPath {
            return Configuration(
                projectDirectory: URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
            )
        }

        guard let bundledProjectDirectoryPath = Bundle.main.object(
            forInfoDictionaryKey: "BCSProjectDirectory"
        ) as? String else {
            fatalError("Missing BCSProjectDirectory in application Info.plist")
        }
        return Configuration(projectDirectory: URL(
            fileURLWithPath: bundledProjectDirectoryPath,
            isDirectory: true
        ))
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
    private let configuration: Configuration
    private let statusItem = NSStatusBar.system.statusItem(withLength: 26)
    private let statusMenuItem = NSMenuItem(title: "Статус: проверка", action: nil, keyEquivalent: "")
    private let connectMenuItem = NSMenuItem(title: "Подключить", action: #selector(connect), keyEquivalent: "")
    private let disconnectMenuItem = NSMenuItem(title: "Отключить", action: #selector(disconnect), keyEquivalent: "")
    private let fallbackProxyServer = FallbackProxyServer()
    private var activeCommand: Process?
    private var fallbackProxyFailure: String?
    private var statusCheckInProgress = false
    private var statusTimer: Timer?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureMenu()
        do {
            try fallbackProxyServer.start()
        } catch {
            fallbackProxyFailure = error.localizedDescription
            applyStatus(.failed)
            showError(title: "Не удалось запустить fallback SOCKS5", details: error.localizedDescription)
        }
        refreshStatus()
        statusTimer = Timer.scheduledTimer(
            withTimeInterval: 3,
            repeats: true,
            block: { [weak self] _ in self?.refreshStatus() }
        )
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        connectMenuItem.target = self
        disconnectMenuItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(connectMenuItem)
        menu.addItem(disconnectMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выйти",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        applyStatus(.checking)
    }

    @objc private func connect() {
        runCommand(scriptName: "connect.sh", progressStatus: .connecting)
    }

    @objc private func disconnect() {
        runCommand(scriptName: "disconnect.sh", progressStatus: .disconnecting)
    }

    private func runCommand(scriptName: String, progressStatus: ConnectionStatus) {
        guard activeCommand == nil else {
            return
        }

        applyStatus(progressStatus)
        connectMenuItem.isEnabled = false
        disconnectMenuItem.isEnabled = false

        let process = Process()
        process.executableURL = configuration.projectDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(scriptName)
        process.currentDirectoryURL = configuration.projectDirectory
        process.environment = ProcessInfo.processInfo.environment

        let logFile = configuration.projectDirectory
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("menu-bar.log")

        do {
            FileManager.default.createFile(
                atPath: logFile.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: logFile.path
            )
            let logHandle = try FileHandle(forWritingTo: logFile)
            try logHandle.truncate(atOffset: 0)
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] completedProcess in
                try? logHandle.close()
                let output = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
                DispatchQueue.main.async {
                    self?.commandDidFinish(exitCode: completedProcess.terminationStatus, output: output)
                }
            }

            activeCommand = process
            try process.run()
        } catch {
            activeCommand = nil
            applyStatus(.unavailable)
            showError(title: "Не удалось запустить команду", details: error.localizedDescription)
        }
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
        process.executableURL = configuration.projectDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("status.sh")
        process.currentDirectoryURL = configuration.projectDirectory
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
            button.title = image == nil ? "VPN" : ""
            button.toolTip = "BCS VPN: \(status.title.replacingOccurrences(of: "Статус: ", with: ""))"
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
