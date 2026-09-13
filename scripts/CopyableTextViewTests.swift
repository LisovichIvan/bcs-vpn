import AppKit
import Foundation

@main
private enum CopyableTextViewTests {
    static func main() {
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
        print("CopyableTextView: частичное выделение и ⌘C работают в английской и русской раскладках.")
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
