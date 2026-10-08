import AppKit
import Darwin
import Foundation

private struct LogSource {
    let title: String
    let fileURL: URL
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: VPNSettingsStore
    private let logSources: [LogSource]
    private let maximumDisplayedLogBytes: UInt64 = 256 * 1_024

    private let serverURLTextField = NSTextField(string: "")
    private let usernameTextField = NSTextField(string: "")
    private let rsaPINTextField = NSSecureTextField(string: "")
    private let certificateSHA1TextField = NSTextField(string: "")
    private let serverCertificatePinTextField = NSTextField(string: "")
    private let settingsStatusLabel = NSTextField(labelWithString: "")
    private let readinessStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let instructionTextView = CopyableTextView(frame: .zero)
    private let checkReadinessButton = NSButton(title: "Проверить готовность", target: nil, action: nil)
    private let launchAtLoginCheckBox = NSButton(
        checkboxWithTitle: "Запускать BCS VPN при входе в macOS",
        target: nil,
        action: nil
    )

    private let logSourcePopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let logPathLabel = NSTextField(labelWithString: "")
    private let logTextView = CopyableTextView(frame: .zero)
    private let openLogButton = NSButton(title: "Открыть файл", target: nil, action: nil)
    private let clearLogButton = NSButton(title: "Очистить", target: nil, action: nil)
    private let openLogsFromSettingsButton = NSButton(title: "Журналы…", target: nil, action: nil)
    private let importSettingsButton = NSButton(title: "Импортировать…", target: nil, action: nil)
    private let exportSettingsButton = NSButton(title: "Экспортировать…", target: nil, action: nil)
    private var logsWindow: NSWindow?
    private var logRefreshTimer: Timer?

    init(projectDirectory: URL) {
        settingsStore = VPNSettingsStore(projectDirectory: projectDirectory)
        let runDirectory = projectDirectory.appendingPathComponent("run", isDirectory: true)
        let applicationLogFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BCS VPN", isDirectory: true)
            .appendingPathComponent("bcs-vpn.log", isDirectory: false)
        logSources = [
            LogSource(title: "Приложение", fileURL: applicationLogFile),
            LogSource(
                title: "Команды меню",
                fileURL: runDirectory.appendingPathComponent("menu-bar.log", isDirectory: false)
            ),
            LogSource(
                title: "OpenConnect",
                fileURL: runDirectory.appendingPathComponent("openconnect.log", isDirectory: false)
            ),
            LogSource(
                title: "ocproxy",
                fileURL: runDirectory.appendingPathComponent("ocproxy.log", isDirectory: false)
            ),
            LogSource(
                title: "OKD Proxy",
                fileURL: runDirectory.appendingPathComponent("okd-proxy.log", isDirectory: false)
            ),
        ]

        super.init(window: nil)
        configureSettingsWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLogRefreshTimer()
    }

    func open() {
        DiagnosticLogger.info("settings.open requested")
        loadSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func openLogs() {
        DiagnosticLogger.info("logs.open requested")
        if logsWindow == nil {
            configureLogsWindow()
        }
        logsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshSelectedLog(forceScrollToEnd: true)
        startLogRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else {
            return
        }
        if closedWindow === logsWindow {
            stopLogRefreshTimer()
        }
    }

    private func configureSettingsWindow() {
        DiagnosticLogger.info("settings.window.configure begin")
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "BCS VPN — Настройки"
        settingsWindow.contentView = makeSettingsView()
        settingsWindow.minSize = NSSize(width: 720, height: 480)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.delegate = self
        window = settingsWindow
        DiagnosticLogger.info("settings.window.configure complete")
    }

    private func configureLogsWindow() {
        let logsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        logsWindow.title = "BCS VPN — Журналы"
        logsWindow.contentView = makeLogsView()
        logsWindow.minSize = NSSize(width: 720, height: 480)
        logsWindow.isReleasedWhenClosed = false
        logsWindow.center()
        logsWindow.delegate = self
        self.logsWindow = logsWindow
    }

    private func makeSettingsView() -> NSView {
        DiagnosticLogger.info("settings.view.build begin")
        serverURLTextField.placeholderString = "https://fw2.bcs.ru"
        usernameTextField.placeholderString = "Имя пользователя"
        rsaPINTextField.placeholderString = "Постоянный PIN"
        certificateSHA1TextField.placeholderString = "40 шестнадцатеричных символов"
        serverCertificatePinTextField.placeholderString = "pin-sha256:..."

        let formStack = NSStackView(views: [
            makeSettingsRow(title: "Шлюз", textField: serverURLTextField),
            makeSettingsRow(title: "Пользователь", textField: usernameTextField),
            makeSettingsRow(title: "Постоянный PIN RSA", textField: rsaPINTextField),
            makeSettingsRow(title: "SHA-1 сертификата", textField: certificateSHA1TextField),
            makeSettingsRow(
                title: "Сертификат сервера",
                textField: serverCertificatePinTextField
            ),
        ])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 14

        updateInstruction(statuses: Array(repeating: false, count: 6))
        instructionTextView.isEditable = false
        instructionTextView.isSelectable = true
        instructionTextView.isRichText = false
        instructionTextView.allowsUndo = false
        instructionTextView.drawsBackground = false
        instructionTextView.font = .systemFont(ofSize: 12)
        instructionTextView.textContainerInset = NSSize(width: 6, height: 6)
        instructionTextView.textContainer?.widthTracksTextView = true
        instructionTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let instructionScrollView = NSScrollView()
        instructionScrollView.borderType = .bezelBorder
        instructionScrollView.hasVerticalScroller = true
        instructionScrollView.autohidesScrollers = true
        instructionScrollView.documentView = instructionTextView

        readinessStatusLabel.maximumNumberOfLines = 0
        readinessStatusLabel.textColor = .secondaryLabelColor
        readinessStatusLabel.isSelectable = true
        checkReadinessButton.target = self
        checkReadinessButton.action = #selector(checkReadiness)

        settingsStatusLabel.maximumNumberOfLines = 2
        settingsStatusLabel.lineBreakMode = .byWordWrapping
        launchAtLoginCheckBox.target = self
        launchAtLoginCheckBox.action = #selector(launchAtLoginDidChange)
        launchAtLoginCheckBox.state = launchAgentIsInstalled ? .on : .off

        let saveButton = NSButton(
            title: "Сохранить",
            target: self,
            action: #selector(saveSettings)
        )
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        openLogsFromSettingsButton.target = self
        openLogsFromSettingsButton.action = #selector(openLogs)
        importSettingsButton.target = self
        importSettingsButton.action = #selector(importSettings)
        exportSettingsButton.target = self
        exportSettingsButton.action = #selector(exportSettings)

        let transferStack = NSStackView(views: [importSettingsButton, exportSettingsButton])
        transferStack.orientation = .horizontal
        transferStack.alignment = .centerY
        transferStack.spacing = 10

        let readinessStack = NSStackView(views: [readinessStatusLabel, NSView(), checkReadinessButton])
        readinessStack.orientation = .horizontal
        readinessStack.alignment = .centerY
        readinessStack.spacing = 12
        readinessStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkReadinessButton.setContentHuggingPriority(.required, for: .horizontal)

        let buttonStack = NSStackView(views: [transferStack, openLogsFromSettingsButton, NSView(), settingsStatusLabel, saveButton])
        let launchAtLoginContainer = NSStackView(views: [launchAtLoginCheckBox, NSView()])
        launchAtLoginContainer.orientation = .horizontal
        launchAtLoginContainer.alignment = .centerY
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.spacing = 12
        settingsStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let contentView = NSView()
        [formStack, instructionScrollView, readinessStack, launchAtLoginContainer, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            formStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            formStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),
            instructionScrollView.topAnchor.constraint(equalTo: formStack.bottomAnchor, constant: 22),
            instructionScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            instructionScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            instructionScrollView.heightAnchor.constraint(equalToConstant: 390),
            readinessStack.topAnchor.constraint(equalTo: instructionScrollView.bottomAnchor, constant: 14),
            readinessStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            readinessStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            launchAtLoginContainer.topAnchor.constraint(equalTo: readinessStack.bottomAnchor, constant: 14),
            launchAtLoginContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            launchAtLoginContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            buttonStack.topAnchor.constraint(equalTo: launchAtLoginContainer.bottomAnchor, constant: 16),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
        DiagnosticLogger.info("settings.view.build complete instructionTextView=true")
        return contentView
    }

    private func updateInstruction(statuses: [Bool]) {
        let marks = statuses.map { $0 ? "✓" : "○" }
        instructionTextView.string = """
        ПОРЯДОК НАСТРОЙКИ ПОСЛЕ УСТАНОВКИ
        Выделите любой фрагмент мышью и нажмите ⌘C.

        \(marks[0]) 1. Сертификат и RSA
        Установите клиентский сертификат BCS в «Связку ключей» и подготовьте приложение RSA SecurID.

        \(marks[1]) 2. Параметры подключения
        Заполните шлюз, пользователя, PIN RSA, SHA-1 сертификата и pin-sha256 сертификата сервера. Нажмите «Сохранить».

        \(marks[2]) 3. Прокси Proxifier
        SOCKS5 · 127.0.0.1 · порт 8889 · без авторизации · DNS через прокси.

        \(marks[3]) 4. Правила Proxifier
        Localhost → Direct
        BCS VPN.app → Direct
        fw2.bcs.ru и 193.142.56.141 → Direct
        BCS through Cisco → SOCKS5 127.0.0.1:8889
        Default → Direct

        \(marks[4]) 5. Цели правила BCS through Cisco
        gitlab.gitlab.bcs.ru; artifactory.gitlab.bcs.ru; confluence.bcs.ru; jira.bcs.ru; apis.tusvc.bcs.ru; *.global.bcs; 193.142.56.242; 193.142.56.243; 172.18.8.20; 172.17.174.48.

        \(marks[5]) 6. Подключение
        Используйте свежий шестизначный код RSA. После успешной проверки можно включить автозапуск.
        """
    }

    @objc private func checkReadiness() {
        DiagnosticLogger.info("settings.readiness.check begin")
        var checks: [String] = []
        let settings = VPNSettings(
            serverURL: serverURLTextField.stringValue,
            username: usernameTextField.stringValue,
            rsaPIN: rsaPINTextField.stringValue,
            certificateSHA1: certificateSHA1TextField.stringValue,
            serverCertificatePin: serverCertificatePinTextField.stringValue
        )
        do {
            _ = try settings.validated()
            checks.append("✓ параметры подключения заполнены")
        } catch {
            checks.append("✗ параметры: \(error.localizedDescription)")
        }

        let runtimeURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/runtime-macos-arm64/bin/openconnect")
        checks.append(FileManager.default.isExecutableFile(atPath: runtimeURL.path)
            ? "✓ VPN runtime установлен"
            : "✗ VPN runtime не найден")

        let proxifierIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.localizedCaseInsensitiveCompare("Proxifier") == .orderedSame
        }
        checks.append(proxifierIsRunning
            ? "✓ Proxifier запущен — правила нужно проверить вручную"
            : "⚠ Proxifier не запущен — настройте его по инструкции выше")
        checks.append("⚠ сертификат в Keychain и правила Proxifier проверяются при подключении")
        readinessStatusLabel.stringValue = checks.joined(separator: "\n")
        readinessStatusLabel.textColor = checks.contains(where: { $0.hasPrefix("✗") })
            ? .systemRed : .secondaryLabelColor
        DiagnosticLogger.info("settings.readiness.check complete invalid=\(checks.contains(where: { $0.hasPrefix("✗") })) proxifierRunning=\(proxifierIsRunning)")

        let statuses = [
            settingsValidated(settings),
            settingsValidated(settings),
            proxifierIsRunning,
            false,
            false,
            false,
        ]
        updateInstruction(statuses: statuses)
    }

    private func settingsValidated(_ settings: VPNSettings) -> Bool {
        (try? settings.validated()) != nil
    }

    private func makeSettingsRow(title: String, textField: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true

        let row = NSStackView(views: [label, textField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func makeLogsView() -> NSView {
        logSourcePopupButton.addItems(withTitles: logSources.map(\.title))
        logSourcePopupButton.target = self
        logSourcePopupButton.action = #selector(logSourceDidChange)
        logSourcePopupButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        openLogButton.target = self
        openLogButton.action = #selector(openSelectedLog)
        clearLogButton.target = self
        clearLogButton.action = #selector(clearSelectedLog)

        let controlsStack = NSStackView(views: [
            logSourcePopupButton,
            NSView(),
            openLogButton,
            clearLogButton,
        ])
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 10

        logPathLabel.textColor = .secondaryLabelColor
        logPathLabel.lineBreakMode = .byTruncatingMiddle

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = false
        logTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let logScrollView = NSScrollView()
        logScrollView.borderType = .bezelBorder
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        logScrollView.documentView = logTextView

        let contentView = NSView()
        [controlsStack, logPathLabel, logScrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            controlsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            controlsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            logPathLabel.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 8),
            logPathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logPathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            logScrollView.topAnchor.constraint(equalTo: logPathLabel.bottomAnchor, constant: 10),
            logScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            logScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        return contentView
    }

    private var launchAgentLabel: String { "com.bcs.vpn" }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    private var launchAgentDomain: String { "gui/\(getuid())" }

    private var launchAgentIsInstalled: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(launchAgentDomain)/\(launchAgentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @objc private func launchAtLoginDidChange() {
        do {
            if launchAtLoginCheckBox.state == .on {
                try installLaunchAgent()
                setSettingsStatus("Автозапуск включён.", color: .systemGreen)
            } else {
                try removeLaunchAgent()
                setSettingsStatus("Автозапуск выключен.", color: .secondaryLabelColor)
            }
        } catch {
            launchAtLoginCheckBox.state = launchAgentIsInstalled ? .on : .off
            setSettingsStatus(error.localizedDescription, color: .systemRed)
        }
    }

    private func installLaunchAgent() throws {
        let applicationURL = Bundle.main.bundleURL
        let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/bcs-vpn")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(domain: "BCSVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сначала установите приложение в ~/Applications."])
        }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executableURL.path],
            "EnvironmentVariables": ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.bcs.vpn"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "AbandonProcessGroup": true,
            "StandardOutPath": applicationLogURL.path,
            "StandardErrorPath": applicationLogURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)
        if !launchAgentIsInstalled {
            try runLaunchctl(["bootstrap", launchAgentDomain, launchAgentURL.path])
        }
        try runLaunchctl(["enable", "\(launchAgentDomain)/\(launchAgentLabel)"])
    }

    private func removeLaunchAgent() throws {
        try runLaunchctl(["bootout", "\(launchAgentDomain)/\(launchAgentLabel)"], ignoreFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private func runLaunchctl(_ arguments: [String], ignoreFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if !ignoreFailure && process.terminationStatus != 0 {
            throw NSError(domain: "BCSVPN", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Не удалось изменить автозапуск BCS VPN."])
        }
    }

    private var applicationLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BCS VPN/bcs-vpn.log", isDirectory: false)
    }

    private func loadSettings() {
        DiagnosticLogger.info("settings.load begin path=\(settingsStore.configurationFileURL.path)")
        launchAtLoginCheckBox.state = launchAgentIsInstalled ? .on : .off
        do {
            let settings = try settingsStore.load()
            applySettings(settings)
            if FileManager.default.fileExists(atPath: settingsStore.configurationFileURL.path) {
                setSettingsStatus("Настройки загружены.", color: .secondaryLabelColor)
            } else {
                setSettingsStatus("Файл vpn-settings.plist ещё не создан.", color: .systemOrange)
            }
            checkReadiness()
            DiagnosticLogger.info("settings.load complete")
        } catch {
            DiagnosticLogger.error("settings.load failed error=\(error.localizedDescription)")
            applySettings(.empty)
            setSettingsStatus(error.localizedDescription, color: .systemRed)
            showError(title: "Не удалось загрузить настройки", details: error.localizedDescription)
        }
    }

    private func applySettings(_ settings: VPNSettings) {
        serverURLTextField.stringValue = settings.serverURL
        usernameTextField.stringValue = settings.username
        rsaPINTextField.stringValue = settings.rsaPIN
        certificateSHA1TextField.stringValue = settings.certificateSHA1
        serverCertificatePinTextField.stringValue = settings.serverCertificatePin
    }

    @objc private func saveSettings() {
        DiagnosticLogger.info("settings.save begin")
        let settings = VPNSettings(
            serverURL: serverURLTextField.stringValue,
            username: usernameTextField.stringValue,
            rsaPIN: rsaPINTextField.stringValue,
            certificateSHA1: certificateSHA1TextField.stringValue,
            serverCertificatePin: serverCertificatePinTextField.stringValue
        )
        do {
            let savedSettings = try settingsStore.save(settings)
            applySettings(savedSettings)
            setSettingsStatus(
                "Сохранено. Изменения применятся при следующем подключении.",
                color: .systemGreen
            )
            checkReadiness()
            DiagnosticLogger.info("settings.save complete")
        } catch {
            DiagnosticLogger.error("settings.save failed error=\(error.localizedDescription)")
            setSettingsStatus(error.localizedDescription, color: .systemRed)
            showError(title: "Не удалось сохранить настройки", details: error.localizedDescription)
        }
    }

    @objc private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Импорт настроек VPN"
        panel.prompt = "Импортировать"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        do {
            let importedSettings = try settingsStore.load(from: fileURL)
            applySettings(importedSettings)
            setSettingsStatus(
                "Профиль импортирован в форму. Нажмите «Сохранить», чтобы применить его.",
                color: .systemOrange
            )
        } catch {
            showError(title: "Не удалось импортировать настройки", details: error.localizedDescription)
        }
    }

    @objc private func exportSettings() {
        let settings = VPNSettings(
            serverURL: serverURLTextField.stringValue,
            username: usernameTextField.stringValue,
            rsaPIN: rsaPINTextField.stringValue,
            certificateSHA1: certificateSHA1TextField.stringValue,
            serverCertificatePin: serverCertificatePinTextField.stringValue
        )

        let panel = NSSavePanel()
        panel.title = "Экспорт настроек VPN"
        panel.prompt = "Экспортировать"
        panel.nameFieldStringValue = "vpn-settings.plist"
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        do {
            try settingsStore.export(settings, to: fileURL)
            setSettingsStatus(
                "Профиль экспортирован. Он содержит PIN RSA — передавайте файл только доверенному пользователю.",
                color: .systemGreen
            )
        } catch {
            setSettingsStatus(error.localizedDescription, color: .systemRed)
            showError(title: "Не удалось экспортировать настройки", details: error.localizedDescription)
        }
    }

    private func setSettingsStatus(_ text: String, color: NSColor) {
        settingsStatusLabel.stringValue = text
        settingsStatusLabel.textColor = color
    }

    @objc private func logSourceDidChange() {
        refreshSelectedLog(forceScrollToEnd: true)
    }

    @objc private func openSelectedLog() {
        guard let logSource = selectedLogSource,
              isRegularFileWithoutSymbolicLink(logSource.fileURL) else {
            showError(title: "Журнал недоступен", details: "Файл журнала ещё не создан.")
            return
        }
        guard NSWorkspace.shared.open(logSource.fileURL) else {
            showError(title: "Не удалось открыть журнал", details: logSource.fileURL.path)
            return
        }
    }

    @objc private func clearSelectedLog() {
        guard let logSource = selectedLogSource,
              isRegularFileWithoutSymbolicLink(logSource.fileURL),
              let logsWindow else {
            return
        }

        let confirmationAlert = NSAlert()
        confirmationAlert.alertStyle = .warning
        confirmationAlert.messageText = "Очистить журнал «\(logSource.title)»?"
        confirmationAlert.informativeText = "Содержимое файла будет удалено без возможности восстановления."
        confirmationAlert.addButton(withTitle: "Очистить")
        confirmationAlert.addButton(withTitle: "Отмена")
        confirmationAlert.beginSheetModal(for: logsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.truncateLog(logSource)
        }
    }

    private func truncateLog(_ logSource: LogSource) {
        let fileDescriptor = logSource.fileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else {
            showError(
                title: "Не удалось очистить журнал",
                details: String(cString: strerror(errno))
            )
            return
        }
        defer {
            Darwin.close(fileDescriptor)
        }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0,
              fileInformation.st_mode & S_IFMT == S_IFREG,
              ftruncate(fileDescriptor, 0) == 0 else {
            showError(
                title: "Не удалось очистить журнал",
                details: String(cString: strerror(errno))
            )
            return
        }
        refreshSelectedLog(forceScrollToEnd: true)
    }

    private var selectedLogSource: LogSource? {
        let selectedIndex = logSourcePopupButton.indexOfSelectedItem
        guard logSources.indices.contains(selectedIndex) else {
            return nil
        }
        return logSources[selectedIndex]
    }

    private func startLogRefreshTimer() {
        guard logRefreshTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshSelectedLog(forceScrollToEnd: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        logRefreshTimer = timer
    }

    private func stopLogRefreshTimer() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
    }

    private func refreshSelectedLog(forceScrollToEnd: Bool) {
        guard let logSource = selectedLogSource else {
            return
        }
        logPathLabel.stringValue = logSource.fileURL.path

        let logFileExists = isRegularFileWithoutSymbolicLink(logSource.fileURL)
        openLogButton.isEnabled = logFileExists
        clearLogButton.isEnabled = logFileExists
        guard logFileExists else {
            updateLogText("Файл журнала ещё не создан.", forceScrollToEnd: false)
            return
        }

        do {
            let logContent = try readLogTail(logSource.fileURL)
            updateLogText(
                logContent.isEmpty ? "Журнал пуст." : logContent,
                forceScrollToEnd: forceScrollToEnd
            )
        } catch {
            updateLogText(
                "Не удалось прочитать журнал: \(error.localizedDescription)",
                forceScrollToEnd: false
            )
        }
    }

    private func readLogTail(_ fileURL: URL) throws -> String {
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
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
        defer {
            try? fileHandle.close()
        }
        let fileSize = try fileHandle.seekToEnd()
        let firstDisplayedByte = fileSize > maximumDisplayedLogBytes
            ? fileSize - maximumDisplayedLogBytes
            : 0
        try fileHandle.seek(toOffset: firstDisplayedByte)
        let data = try fileHandle.read(upToCount: Int(maximumDisplayedLogBytes)) ?? Data()
        let content = String(decoding: data, as: UTF8.self)
        guard firstDisplayedByte > 0 else {
            return content
        }
        return "[Показаны последние 256 КБ журнала]\n" + content
    }

    private func isRegularFileWithoutSymbolicLink(_ fileURL: URL) -> Bool {
        var fileInformation = stat()
        let result = fileURL.path.withCString {
            lstat($0, &fileInformation)
        }
        return result == 0 && fileInformation.st_mode & S_IFMT == S_IFREG
    }

    private func updateLogText(_ content: String, forceScrollToEnd: Bool) {
        guard logTextView.string != content else {
            return
        }

        let visibleMaximumY = logTextView.enclosingScrollView?.contentView.bounds.maxY ?? 0
        let distanceToBottom = logTextView.bounds.height - visibleMaximumY
        let previousSelection = logTextView.selectedRange()
        let shouldScrollToEnd = forceScrollToEnd || (
            previousSelection.length == 0 && (logTextView.string.isEmpty || distanceToBottom < 40)
        )

        logTextView.string = content
        if shouldScrollToEnd {
            logTextView.scrollToEndOfDocument(nil)
        } else {
            let contentLength = (content as NSString).length
            let selectionLocation = min(previousSelection.location, contentLength)
            let selectionLength = min(previousSelection.length, contentLength - selectionLocation)
            logTextView.setSelectedRange(NSRange(location: selectionLocation, length: selectionLength))
        }
    }

    private func showError(title: String, details: String) {
        DiagnosticLogger.error("ui.alert title=\(title) details=\(details)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        let presentingWindow = logsWindow?.isKeyWindow == true ? logsWindow : window
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow)
        } else {
            alert.runModal()
        }
    }
}
