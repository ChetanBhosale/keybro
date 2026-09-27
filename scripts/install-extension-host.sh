#!/bin/sh
# Registers the keybro native messaging host with Chromium browsers that are installed.
# The extension (extension/chrome, ID below) can then send the current conversation to keybro.
set -eu
HOST="$1"
ID="ngpdafelbfkdafghbcobkckcefeplapa"
BASE="$HOME/Library/Application Support"
for dir in "Google/Chrome" "Arc/User Data" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Chromium" "Vivaldi"; do
  if [ -d "$BASE/$dir" ]; then
    mkdir -p "$BASE/$dir/NativeMessagingHosts"
    cat > "$BASE/$dir/NativeMessagingHosts/dev.chetan.keybro.json" <<JSON
{
  "name": "dev.chetan.keybro",
  "description": "keybro: current conversation from the browser",
  "path": "$HOST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$ID/"]
}
JSON
    echo "Registered with $dir"
  fi
done
