import AppKit

final class CopyableTextView: NSTextView {
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= (string as NSString).length else {
            return
        }
        let selectedText = (string as NSString).substring(with: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        DiagnosticLogger.info("text.copy selectedCharacters=\(range.length)")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           selectedRange().length > 0 {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
