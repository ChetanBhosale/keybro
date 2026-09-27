// Forwards the current conversation to the keybro native host on this Mac. Nothing leaves the machine.
chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "context" || !sender.tab?.active) return;
  chrome.runtime.sendNativeMessage("dev.chetan.keybro", {
    surface: message.surface,
    contact: message.contact,
    title: message.title,
    url: message.url,
    ts: Date.now() / 1000,
  }, () => void chrome.runtime.lastError);
});
