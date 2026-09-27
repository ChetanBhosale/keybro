import Foundation
import KeybroKit

// Chrome native messaging host for the keybro extension. Chrome starts it per message.
// Saves the latest web context to ~/keybro-memory/.web-context.json and replies {"ok":true}.
var buffer = Data()
let input = FileHandle.standardInput
while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    for message in NativeMessaging.unframe(&buffer) {
        if var context = try? JSONDecoder().decode(WebContext.self, from: message) {
            if SensitiveContent.shouldSkip(text: context.contact, windowTitle: context.title) {
                context.contact = nil
            }
            try? context.save()
        }
        FileHandle.standardOutput.write(NativeMessaging.frame(Data(#"{"ok":true}"#.utf8)))
    }
}
