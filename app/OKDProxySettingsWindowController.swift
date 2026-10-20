import AppKit
import Foundation

final class OKDProxySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: OKDProxySettingsStore
    private let serverURLField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let namespaceField = NSTextField(string: "")
    private let selectorField = NSTextField(string: "")
    private let configurationLoader: OKDProxyConfigurationLoader
    private let forwardsTextView = CopyableTextView()
    private let configurationStatusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Обновить пробросы", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(dataDirectory: URL, configurationLoader: OKDProxyConfigurationLoader = OKDProxyConfigurationLoader()) {
        store = OKDProxySettingsStore(dataDirectory: dataDirectory)
        self.configurationLoader = configurationLoader
        super.init(window: nil)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        loadSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshForwards()
    }

    func windowWillClose(_ notification: Notification) {
        configurationLoader.cancel()
        refreshButton.isEnabled = true
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 760)
        window.title = "BCS VPN — OKD Proxy"
        window.contentView = makeView()
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
    }

    private func makeView() -> NSView {
        serverURLField.placeholderString = "https://okd.example:443"
        tokenField.placeholderString = "Token ServiceAccount или пользователя (необязательно)"
        usernameField.placeholderString = "Логин OKD (необязательно)"
        passwordField.placeholderString = "Пароль OKD (необязательно)"
        namespaceField.placeholderString = "crm-common"
        selectorField.placeholderString = "app=crm-db-proxy"

        let form = NSStackView(views: [
            row("Адрес OKD", serverURLField),
            row("Token", tokenField),
            row("Логин", usernameField),
            row("Пароль", passwordField),
            row("Namespace", namespaceField),
            row("Selector pod", selectorField),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12

        let hint = NSTextField(wrappingLabelWithString: "Первый Running pod в указанном namespace по selector. Порты загружаются из GitLab при каждом подключении через glab: только TCP, без записей _…, без дублей. При ошибке загрузки подключение не запускается. Учётные данные OKD сохраняются в файле с правами 600.")
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0

        let sourceLabel = NSTextField(wrappingLabelWithString: "Источник: \(OKDProxyConfiguration.sourceURL)")
        sourceLabel.isSelectable = true
        let previewLabel = NSTextField(wrappingLabelWithString: "Просмотр develop, не состояние активного подключения. Локальный адрес → порт pod → назначение из config.json (TCP).")
        previewLabel.textColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshForwards)
        refreshButton.bezelStyle = .rounded
        let configurationButtons = NSStackView(views: [configurationStatusLabel, NSView(), refreshButton])
        configurationButtons.orientation = .horizontal
        configurationButtons.spacing = 12
        configurationStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configurationStatusLabel.maximumNumberOfLines = 3
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        forwardsTextView.isEditable = false
        forwardsTextView.isSelectable = true
        forwardsTextView.isRichText = false
        forwardsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        forwardsTextView.autoresizingMask = [.width]
        forwardsTextView.isVerticallyResizable = true
        forwardsTextView.isHorizontallyResizable = false
        forwardsTextView.textContainer?.widthTracksTextView = true
        forwardsTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        forwardsTextView.textContainerInset = NSSize(width: 8, height: 8)
        let forwardsScrollView = NSScrollView()
        forwardsScrollView.hasVerticalScroller = true
        forwardsScrollView.borderType = .bezelBorder
        forwardsScrollView.documentView = forwardsTextView
        let configurationView = NSStackView(views: [sourceLabel, previewLabel, configurationButtons, forwardsScrollView])
        configurationView.orientation = .vertical
        configurationView.alignment = .leading
        configurationView.spacing = 8
        for view in [sourceLabel, previewLabel, configurationButtons, forwardsScrollView] {
            view.widthAnchor.constraint(equalTo: configurationView.widthAnchor).isActive = true
        }
        forwardsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [statusLabel, NSView(), saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSView()
        [form, hint, configurationView, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            configurationView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
            configurationView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            configurationView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: configurationView.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func row(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 510).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func loadSettings() {
        do {
            apply(try store.load())
            statusLabel.stringValue = "Настройки загружены."
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            apply(.empty)
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
    }

    private func apply(_ settings: OKDProxySettings) {
        serverURLField.stringValue = settings.serverURL
        tokenField.stringValue = settings.token
        usernameField.stringValue = settings.username
        passwordField.stringValue = settings.password
        namespaceField.stringValue = settings.namespace
        selectorField.stringValue = settings.podSelector
    }

    @objc private func refreshForwards() {
        refreshButton.isEnabled = false
        forwardsTextView.string = ""
        configurationStatusLabel.stringValue = "Загрузка config.json из GitLab…"
        configurationStatusLabel.textColor = .secondaryLabelColor
        configurationLoader.load { [weak self] result in
            guard let self else { return }
            self.refreshButton.isEnabled = true
            switch result {
            case let .success(configuration):
                self.forwardsTextView.string = configuration.forwards.map(\.description).joined(separator: "\n\n")
                self.configurationStatusLabel.stringValue = "TCP-сервисов: \(configuration.forwards.count), уникальных портов: \(Set(configuration.forwards.map(\.localPort)).count)."
                self.configurationStatusLabel.textColor = .secondaryLabelColor
            case let .failure(error):
                self.configurationStatusLabel.stringValue = error.localizedDescription
                self.configurationStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func save() {
        let settings = OKDProxySettings(
            serverURL: serverURLField.stringValue,
            token: tokenField.stringValue,
            username: usernameField.stringValue,
            password: passwordField.stringValue,
            namespace: namespaceField.stringValue,
            podSelector: selectorField.stringValue
        )
        do {
            apply(try store.save(settings))
            statusLabel.stringValue = "Сохранено. Перезапустите OKD Proxy для применения."
            statusLabel.textColor = .systemGreen
            DiagnosticLogger.info("okd.settings.save server=\(settings.serverURL) namespace=\(settings.namespace) selector=\(settings.podSelector)")
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
    }
}
