// Finds the name of the conversation you're in and tells keybro (on this Mac only).
// Selectors are best effort: web apps change their markup, so each site has fallbacks
// and anything not found is simply not sent.
(() => {
  const text = (el) => (el && (el.getAttribute("title") || el.textContent || "").trim()) || null;
  const first = (...selectors) => {
    for (const s of selectors) {
      const el = document.querySelector(s);
      const t = text(el);
      if (t && t.length <= 80) return t;
    }
    return null;
  };

  const sites = {
    "web.whatsapp.com": () => ({ surface: "whatsapp", contact: first("#main header span[dir='auto'][title]", "#main header span[title]", "#main header [data-testid='conversation-info-header-chat-title']") }),
    "mail.google.com": () => ({
      surface: "gmail",
      contact: (() => {
        // Composing: first recipient. Reading: the sender.
        const to = document.querySelector("div[aria-label^='To'] span[email], div[name='to'] span[email]");
        if (to) return to.getAttribute("name") || to.getAttribute("email");
        const from = document.querySelector("h3 span[email][name], span.gD[email]");
        return from ? from.getAttribute("name") || from.getAttribute("email") : null;
      })(),
    }),
    "app.slack.com": () => ({ surface: "slack", contact: first("[data-qa='channel_name']", "button[data-qa='channel_header__name'] span", ".p-view_header__channel_title") }),
    "www.linkedin.com": () => ({ surface: "linkedin", contact: first(".msg-entity-lockup__entity-title", "h2.msg-overlay-bubble-header__title", ".msg-thread__link-to-profile .truncate") }),
    "x.com": () => ({ surface: "x", contact: first("[data-testid='DmActivityContainer'] h2 span", "[data-testid='DMConversationHeader'] span") }),
    "web.telegram.org": () => ({ surface: "telegram", contact: first(".chat-info .peer-title", ".ChatInfo .fullName", ".top .peer-title") }),
    "discord.com": () => ({ surface: "discord", contact: first("section[aria-label='Channel header'] h1", "h1[class*='title']") }),
  };

  const read = sites[location.hostname];
  if (!read) return;

  let last = "";
  const report = () => {
    if (document.visibilityState !== "visible") return;
    const { surface, contact } = read();
    const payload = JSON.stringify({ surface, contact, title: document.title });
    if (payload === last) return;
    last = payload;
    chrome.runtime.sendMessage({ type: "context", surface, contact, title: document.title, url: location.origin + location.pathname });
  };

  let timer = null;
  new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(report, 400);
  }).observe(document.body, { childList: true, subtree: true, characterData: true });
  document.addEventListener("visibilitychange", () => { last = ""; report(); });
  window.addEventListener("focus", () => { last = ""; report(); });
  report();
})();
