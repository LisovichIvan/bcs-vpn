import AppKit
import Foundation

// Keep UI tests from writing diagnostics into the installed application's log.
enum DiagnosticLogger {
    private(set) static var messages: [String] = []

    static func info(_ message: String) {
        messages.append(message)
    }

    static func error(_ message: String) {
        messages.append(message)
    }
}

@main
private enum CopyableTextViewTests {
    static func main() throws {
        _ = NSApplication.shared
        let view = CopyableTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.string = "первая строка\nSOCKS5 127.0.0.1:8889\nтретья строка"
        view.isEditable = false
        view.isSelectable = true

        assertCopy(view, selectedText: "127.0.0.1", keyboardCharacters: nil)
        assertCopy(view, selectedText: "SOCKS5 127.0.0.1:8889", keyboardCharacters: "c")
        assertCopy(view, selectedText: "строка\nSOCKS5", keyboardCharacters: "с")
        assertCopy(
            view,
            selectedText: "третья",
            keyboardCharacters: "С",
            modifierFlags: [.command, .capsLock]
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.copy(nil)
        precondition(
            NSPasteboard.general.string(forType: .string) == "unchanged",
            "Пустое выделение не должно менять буфер обмена"
        )
        precondition(
            DiagnosticLogger.messages.contains("text.copy selectedCharacters=9"),
            "Копирование должно записывать только длину выделения в диагностику"
        )
        try assertLogsWindowCopy()
        print("CopyableTextView: ⌘C работает в обеих раскладках; окно журналов сохраняет выделение при обновлении.")
    }

    private static func assertLogsWindowCopy() throws {
        precondition(CommandLine.arguments.count == 2, "Укажите каталог теста")
        let projectDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let runDirectory = projectDirectory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let logFileURL = runDirectory.appendingPathComponent("menu-bar.log")
        let initialContent = "первая строка\nSOCKS5 127.0.0.1:8889\nтретья строка\n"
        try initialContent.write(to: logFileURL, atomically: true, encoding: .utf8)

        let controller = SettingsWindowController(projectDirectory: projectDirectory)
        controller.openLogs()
        guard let logsWindow = NSApplication.shared.windows.first(where: {
            $0.title == "BCS VPN — Журналы"
        }), let contentView = logsWindow.contentView,
            let sourcePopup = descendant(of: NSPopUpButton.self, in: contentView),
            let textView = descendant(of: CopyableTextView.self, in: contentView) else {
            preconditionFailure("Окно журналов должно использовать CopyableTextView")
        }
        defer {
            logsWindow.close()
            controller.close()
        }
        sourcePopup.selectItem(withTitle: "Команды меню")
        precondition(sourcePopup.sendAction(sourcePopup.action, to: sourcePopup.target))
        precondition(textView.string == initialContent, "Тестовый журнал не загружен")

        assertCopy(textView, selectedText: "SOCKS5 127.0.0.1:8889", keyboardCharacters: "c")
        assertCopy(textView, selectedText: "строка\nSOCKS5", keyboardCharacters: "с")
        assertCopy(textView, selectedText: initialContent, keyboardCharacters: "c")
        assertCopy(textView, selectedText: "третья строка", keyboardCharacters: "с")
        let selectedRange = textView.selectedRange()
        let updatedContent = initialContent + "новая строка\n"
        try updatedContent.write(to: logFileURL, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
        precondition(textView.string == updatedContent, "Журнал не обновился по таймеру")
        precondition(
            textView.selectedRange() == selectedRange,
            "Обновление журнала у нижнего края не должно сбрасывать выделение"
        )
        textView.copy(nil)
        precondition(NSPasteboard.general.string(forType: .string) == "третья строка")
    }

    private static func descendant<View: NSView>(of viewType: View.Type, in parent: NSView) -> View? {
        if let matchingView = parent as? View {
            return matchingView
        }
        for child in parent.subviews {
            if let matchingView = descendant(of: viewType, in: child) {
                return matchingView
            }
        }
        return nil
    }

    private static func assertCopy(
        _ view: CopyableTextView,
        selectedText: String,
        keyboardCharacters: String?,
        modifierFlags: NSEvent.ModifierFlags = .command
    ) {
        let range = (view.string as NSString).range(of: selectedText)
        precondition(range.location != NSNotFound, "Тестовый фрагмент не найден")
        view.setSelectedRange(range)
        NSPasteboard.general.clearContents()

        if let keyboardCharacters {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: keyboardCharacters,
                charactersIgnoringModifiers: keyboardCharacters,
                isARepeat: false,
                keyCode: 8
            )!
            precondition(view.performKeyEquivalent(with: event), "⌘C не был обработан")
        } else {
            view.copy(nil)
        }

        let copiedText = NSPasteboard.general.string(forType: .string)
        precondition(
            copiedText == selectedText,
            "Ожидалось «\(selectedText)», скопировано «\(copiedText ?? "nil")»"
        )
    }
}
