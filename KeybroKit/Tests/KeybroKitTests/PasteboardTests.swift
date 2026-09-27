import AppKit
import Testing
@testable import KeybroKit

@MainActor
struct PasteboardTests {
    let pb = NSPasteboard(name: .init("keybro-test-\(UUID().uuidString)"))

    @Test func snapshotRestoresEveryItemAndType() {
        pb.clearContents()
        let a = NSPasteboardItem()
        a.setString("hello", forType: .string)
        a.setString("<b>hello</b>", forType: .html)
        let b = NSPasteboardItem()
        b.setData(Data([1, 2, 3]), forType: .init("com.example.custom"))
        pb.writeObjects([a, b])

        let snapshot = PasteboardSnapshot.take(pb)
        Pasteboard.writeTransient("fixed text", to: pb)
        #expect(pb.string(forType: .string) == "fixed text")
        #expect(pb.types?.contains(.init("org.nspasteboard.TransientType")) == true)

        snapshot.restore(to: pb)
        let items = pb.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].string(forType: .html) == "<b>hello</b>")
        #expect(items[1].data(forType: .init("com.example.custom")) == Data([1, 2, 3]))
    }

    @Test func emptyClipboardStaysEmpty() {
        pb.clearContents()
        let snapshot = PasteboardSnapshot.take(pb)
        Pasteboard.writeTransient("temp", to: pb)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func waitForStringSeesNewCopyAndTimesOut() async {
        pb.clearContents()
        let count = pb.changeCount
        #expect(await Pasteboard.waitForString(after: count, timeout: .milliseconds(60), pasteboard: pb) == nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            pb.clearContents()
            pb.setString("copied", forType: .string)
        }
        #expect(await Pasteboard.waitForString(after: count, timeout: .milliseconds(500), pasteboard: pb) == "copied")
    }
}
