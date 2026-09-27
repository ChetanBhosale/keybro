import AppKit
import ApplicationServices

/// Thin wrappers over the Accessibility C API. Attribute names are literals because the
/// imported kAX* globals aren't concurrency safe under Swift 6.
@MainActor
enum AX {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    static func focusedElement(in pid: pid_t) -> AXUIElement? {
        guard let value = attribute(application(pid), "AXFocusedUIElement"),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    static func focusedWindowTitle(in pid: pid_t) -> String? {
        guard let window = attribute(application(pid), "AXFocusedWindow"),
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return string(window as! AXUIElement, "AXTitle")
    }

    /// Best guess at the conversation name shown in a chat app's header: the first short static
    /// text near the top of the right-hand pane. Only used for apps whose window title doesn't say.
    static func conversationHeader(in pid: pid_t, appName: String?) -> String? {
        guard let windowRef = attribute(application(pid), "AXFocusedWindow"),
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement
        guard let frame = frame(of: window) else { return nil }
        let ignored: Set<String> = ["whatsapp", "messages", "chats", "search", "online", "typing…", "typing...", "new chat",
                                    "archived", "calls", "status", "communities", "settings", "edit", "imessage"]
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = string(element, "AXRole")
            if role == "AXStaticText" || role == "AXHeading",
               let text = (string(element, "AXValue") ?? string(element, "AXTitle"))?.trimmingCharacters(in: .whitespacesAndNewlines),
               (2...60).contains(text.count), !ignored.contains(text.lowercased()), text != appName,
               !text.lowercased().hasPrefix("last seen"), !text.contains("\n"),
               let f = AX.frame(of: element),
               f.maxY >= frame.maxY - frame.height * 0.14,     // top band (AppKit coordinates)
               f.minX >= frame.minX + frame.width * 0.28 {     // right-hand pane
                return text
            }
            guard depth < 14, let children = attribute(element, "AXChildren") as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    /// Electron apps (Slack, Discord, VS Code) only build their tree when asked.
    static func enableManualAccessibility(_ pid: pid_t) {
        AXUIElementSetAttributeValue(application(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func range(_ element: AXUIElement, _ name: String) -> NSRange? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ name: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value as CFString) == .success
    }

    @discardableResult
    static func setRange(_ element: AXUIElement, _ name: String, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    /// Screen rect of a text range, converted to AppKit coordinates.
    static func bounds(of range: NSRange, in element: AXUIElement) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString, param, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 else { return nil }
        return toAppKit(rect)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return toAppKit(CGRect(origin: point, size: size))
    }

    /// Accessibility uses a top-left origin on the primary screen; AppKit uses bottom-left.
    static func toAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
