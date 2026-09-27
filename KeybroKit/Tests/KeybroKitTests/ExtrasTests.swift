import Foundation
import Testing
@testable import KeybroKit

struct PreferencesTests {
    @Test func savedCommandsExpandWithDetails() {
        let c = SavedCommands()
        #expect(c.expand("/decline") == SavedCommands.defaults["decline"])
        #expect(c.expand("/Decline too busy this week")?.hasSuffix("Details: too busy this week") == true)
        #expect(c.expand("/nope") == nil)
        #expect(c.expand("sorry to rahul") == nil)
    }

    @Test func modesAndCommandsRoundTripThroughFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kb-prefs-\(UUID().uuidString)")
        var modes = AppModes()
        modes.modes["slack"] = "Always bullet points."
        try modes.save(to: dir.appending(path: "modes.json"))
        #expect(AppModes.load(from: dir.appending(path: "modes.json")).instructions(for: "slack") == "Always bullet points.")
        #expect(AppModes.load(from: dir.appending(path: "missing.json")) == AppModes())
        #expect(AppModes().instructions(for: "unknown-app") == nil)
    }

    @Test func modeReachesPrompts() {
        #expect(GeneratePrompt.userPrompt(GenerateInput(instruction: "hi", mode: "Work chat.")).contains("<mode>Work chat.</mode>"))
        #expect(FixPrompt.systemPrompt(style: nil, mode: "Email.").contains("Where this text is going: Email."))
        #expect(!FixPrompt.systemPrompt(style: nil).contains("Where this text is going"))
    }
}

struct AskTests {
    @Test func answersParseAndUseTheAskPrompt() {
        #expect(GenerateDraft.parse("<answer>8pm at his place</answer>").answer == "8pm at his place")
        let request = ClaudeGenerator(runner: ClaudeRunner(executablePath: "/x"), style: nil)
            .request(for: { var i = GenerateInput(instruction: "what time?"); i.isQuestion = true; return i }())
        let s = try! #require(request.arguments.firstIndex(of: "--system-prompt"))
        #expect(request.arguments[s + 1].contains("<answer>"))
    }
}

@MainActor
struct GenerateExtrasTests {
    func caret(_ value: String) -> CaptureResult {
        .target(TextTarget(pid: 42, appName: "WhatsApp", text: "", source: .axSelection,
                           range: NSRange(location: (value as NSString).length, length: 0), fullValue: value))
    }

    func controller(_ driver: FakeDriver, inputs: InputLog, reply: GenerateDraft = GenerateDraft(variants: [.casual: "cant make it bro"]),
                    mode: String? = nil) -> GenerateController {
        GenerateController(driver: driver, screenshotter: { _ in nil }, generator: { input in
            AsyncThrowingStream { c in Task { await inputs.record(input); c.yield(reply); c.finish() } }
        }, modeFor: { _ in mode })
    }

    func wait(_ c: GenerateController, _ phase: GenerateController.Phase) async {
        for _ in 0..<300 where c.phase != phase { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func slashLineInTheFieldRunsImmediatelyAndIsReplaced() async {
        let value = "hey\n/sorry to rahul cant come"
        let driver = FakeDriver(caret(value))
        let inputs = InputLog()
        let c = controller(driver, inputs: inputs)
        await c.start()
        await wait(c, .ready)
        #expect(await inputs.all.first?.instruction == "sorry to rahul cant come")
        await c.insert()
        #expect(driver.replaced == ["cant make it bro"])
        #expect(driver.replacedTargets.first?.range == NSRange(location: 4, length: 25))
    }

    @Test func slashCommandInFieldExpandsSavedCommand() async {
        let driver = FakeDriver(caret("/decline"))
        let inputs = InputLog()
        let c = controller(driver, inputs: inputs)
        await c.start()
        await wait(c, .ready)
        #expect(await inputs.all.first?.instruction == SavedCommands.defaults["decline"])
    }

    @Test func slashLineThatChangedIsNotOverwritten() async {
        let driver = FakeDriver(caret("/sorry cant come"))
        let c = controller(driver, inputs: InputLog())
        await c.start()
        await wait(c, .ready)
        driver.insertCapture = caret("/sorry cant come tonight")
        await c.insert()
        #expect(driver.replaced.isEmpty)
        #expect(driver.copied == ["cant make it bro"])
    }

    @Test func plainFieldTextIsNotASlashCommand() async {
        let driver = FakeDriver(caret("see /usr/bin"))
        let c = controller(driver, inputs: InputLog())
        await c.start()
        #expect(c.phase == .composing)
        #expect(GenerateController.slashLine(in: TextTarget(pid: 1, text: "", source: .axSelection, range: NSRange(location: 2, length: 0), fullValue: "//")) == nil)
    }

    @Test func questionsAreAnsweredAndCopiedNotInserted() async {
        let driver = FakeDriver(caret(""))
        let inputs = InputLog()
        let c = controller(driver, inputs: inputs, reply: GenerateDraft(contact: nil, variants: [:]).with(answer: "8pm at his place"))
        await c.start()
        c.submit("? what time is the party")
        await wait(c, .ready)
        #expect(await inputs.all.first?.isQuestion == true)
        #expect(await inputs.all.first?.instruction == "what time is the party")
        #expect(c.currentText == "8pm at his place")
        await c.insert()
        #expect(driver.replaced.isEmpty)
        #expect(driver.copied == ["8pm at his place"])
        #expect(c.copiedAnswer)
    }

    @Test func perAppModeIsPassedToGenerate() async {
        let inputs = InputLog()
        let c = controller(FakeDriver(caret("")), inputs: inputs, mode: "Casual texting.")
        await c.start()
        c.submit("say hi")
        await wait(c, .ready)
        #expect(await inputs.all.first?.mode == "Casual texting.")
    }
}

extension GenerateDraft {
    func with(answer: String) -> GenerateDraft {
        var d = self
        d.answer = answer
        return d
    }
}

struct WebContextTests {
    @Test func framingRoundTripsAndHandlesPartialMessages() {
        let a = Data(#"{"surface":"whatsapp"}"#.utf8)
        let b = Data(#"{"x":1}"#.utf8)
        var buffer = NativeMessaging.frame(a) + NativeMessaging.frame(b).prefix(6)
        #expect(NativeMessaging.unframe(&buffer) == [a])
        buffer += NativeMessaging.frame(b).dropFirst(6)
        #expect(NativeMessaging.unframe(&buffer) == [b])
        #expect(buffer.isEmpty)
    }

    @Test func onlyTrustedForTheTabShowing() {
        let now = Date()
        let web = WebContext(surface: "whatsapp", contact: "Rahul", title: "WhatsApp", url: "https://web.whatsapp.com/", ts: now.timeIntervalSince1970)
        #expect(web.matches(windowTitle: "WhatsApp - Google Chrome", now: now))
        #expect(!web.matches(windowTitle: "Inbox - Gmail", now: now))
        #expect(!web.matches(windowTitle: "WhatsApp", now: now.addingTimeInterval(7 * 3600)))
    }

    @Test func recorderUsesExtensionContactForBrowserTabs() async throws {
        let store = try MemoryStore()
        let dir = FileManager.default.temporaryDirectory.appending(path: "kb-web-\(UUID().uuidString)")
        let file = dir.appending(path: "web.json")
        try WebContext(surface: "whatsapp", contact: "Rahul", title: "WhatsApp", url: nil, ts: Date().timeIntervalSince1970).save(to: file)
        let recorder = MemoryRecorder(store: store)
        await recorder.setWebContextURL(file)
        let convo = await recorder.conversation(bundleID: "com.google.Chrome", windowTitle: "WhatsApp - Google Chrome")
        #expect(convo == Conversation(surface: "whatsapp", contact: "Rahul"))
        let other = await recorder.conversation(bundleID: "com.google.Chrome", windowTitle: "Hacker News")
        #expect(other.contact == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func headerHintsNameNativeChats() async throws {
        let recorder = MemoryRecorder(store: try MemoryStore())
        await recorder.setWebContextURL(nil)
        await recorder.noteHeader("Priya", bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp")
        #expect(await recorder.conversation(bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp").contact == "Priya")
    }
}
