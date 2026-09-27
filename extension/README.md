# keybro browser extension

Tells keybro who you're chatting with on web apps (WhatsApp Web, Gmail, Slack, LinkedIn, X, Telegram, Discord), so memory and Generate know the contact. It only talks to the keybro helper on this Mac through Chrome native messaging. No network requests.

## Install (Chrome, Arc, Brave, Edge)
1. `make extension` (builds the helper and registers it with your browsers)
2. Open `chrome://extensions`, turn on Developer mode, click **Load unpacked**, pick `extension/chrome`
3. The extension ID must be `ngpdafelbfkdafghbcobkckcefeplapa` (fixed by the key in manifest.json)

Selectors are best effort. If a site changes its markup, that site just stops reporting a name; nothing breaks.
