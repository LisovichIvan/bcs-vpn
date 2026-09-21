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
    private let portsField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(dataDirectory: URL) {
        store = OKDProxySettingsStore(dataDirectory: dataDirectory)
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
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
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
        portsField.placeholderString = OKDProxySettings.defaultPorts

        let form = NSStackView(views: [
            row("Адрес OKD", serverURLField),
            row("Token", tokenField),
            row("Логин", usernameField),
            row("Пароль", passwordField),
            row("Namespace", namespaceField),
            row("Selector pod", selectorField),
            row("Порты", portsField),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12

        let hint = NSTextField(wrappingLabelWithString: "OKD Proxy найдёт первый Running pod по selector и будет автоматически перезапускать oc port-forward после его остановки. Token сохраняется в защищённом файле с правами 600.")
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0

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
        [form, hint, buttons].forEach {
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
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
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
        portsField.stringValue = settings.ports
    }

    @objc private func save() {
        let settings = OKDProxySettings(
            serverURL: serverURLField.stringValue,
            token: tokenField.stringValue,
            username: usernameField.stringValue,
            password: passwordField.stringValue,
            namespace: namespaceField.stringValue,
            podSelector: selectorField.stringValue,
            ports: portsField.stringValue
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
