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

    private let logSourcePopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let logPathLabel = NSTextField(labelWithString: "")
    private let logTextView = NSTextView(frame: .zero)
    private let openLogButton = NSButton(title: "Открыть файл", target: nil, action: nil)
    private let clearLogButton = NSButton(title: "Очистить", target: nil, action: nil)
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
        ]

        super.init(window: nil)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLogRefreshTimer()
    }

    func open() {
        loadSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshSelectedLog(forceScrollToEnd: true)
        startLogRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopLogRefreshTimer()
    }

    private func configureWindow() {
        let tabViewController = NSTabViewController()
        tabViewController.addTabViewItem(makeTabViewItem(
            title: "Настройки",
            view: makeSettingsView()
        ))
        tabViewController.addTabViewItem(makeTabViewItem(
            title: "Журналы",
            view: makeLogsView()
        ))

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "BCS VPN"
        settingsWindow.contentViewController = tabViewController
        settingsWindow.minSize = NSSize(width: 720, height: 480)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.delegate = self
        window = settingsWindow
    }

    private func makeTabViewItem(title: String, view: NSView) -> NSTabViewItem {
        let viewController = NSViewController()
        viewController.view = view
        let tabViewItem = NSTabViewItem(viewController: viewController)
        tabViewItem.label = title
        return tabViewItem
    }

    private func makeSettingsView() -> NSView {
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

        let explanationLabel = NSTextField(wrappingLabelWithString:
            "Настройки сохраняются в локальном vpn-settings.plist. Изменения используются при следующем подключении."
        )
        explanationLabel.textColor = .secondaryLabelColor

        settingsStatusLabel.maximumNumberOfLines = 2
        settingsStatusLabel.lineBreakMode = .byWordWrapping

        let saveButton = NSButton(
            title: "Сохранить",
            target: self,
            action: #selector(saveSettings)
        )
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [settingsStatusLabel, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.spacing = 12
        settingsStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let contentView = NSView()
        [formStack, explanationLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            formStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            formStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),
            explanationLabel.topAnchor.constraint(equalTo: formStack.bottomAnchor, constant: 22),
            explanationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            explanationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
        return contentView
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

    private func loadSettings() {
        do {
            let settings = try settingsStore.load()
            applySettings(settings)
            if FileManager.default.fileExists(atPath: settingsStore.configurationFileURL.path) {
                setSettingsStatus("Настройки загружены.", color: .secondaryLabelColor)
            } else {
                setSettingsStatus("Файл vpn-settings.plist ещё не создан.", color: .systemOrange)
            }
        } catch {
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
        } catch {
            setSettingsStatus(error.localizedDescription, color: .systemRed)
            showError(title: "Не удалось сохранить настройки", details: error.localizedDescription)
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
              let window else {
            return
        }

        let confirmationAlert = NSAlert()
        confirmationAlert.alertStyle = .warning
        confirmationAlert.messageText = "Очистить журнал «\(logSource.title)»?"
        confirmationAlert.informativeText = "Содержимое файла будет удалено без возможности восстановления."
        confirmationAlert.addButton(withTitle: "Очистить")
        confirmationAlert.addButton(withTitle: "Отмена")
        confirmationAlert.beginSheetModal(for: window) { [weak self] response in
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
        let shouldScrollToEnd = forceScrollToEnd || logTextView.string.isEmpty || distanceToBottom < 40
        let previousSelection = logTextView.selectedRange()

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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
