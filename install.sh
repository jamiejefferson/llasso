#!/bin/sh
# Installs the latest Llasso and opens it.
#   curl -fsSL https://raw.githubusercontent.com/jamiejefferson/llasso/main/install.sh | sh
# A download made by curl carries no quarantine mark, so macOS opens Llasso with no warning.
set -e

REPO="jamiejefferson/llasso"
# Update the copy already installed, so it keeps its permissions; otherwise /Applications.
if [ -n "$LLASSO_INSTALL_DIR" ]; then DEST="$LLASSO_INSTALL_DIR"
elif [ -d "$HOME/Applications/Llasso.app" ] && [ ! -d "/Applications/Llasso.app" ]; then DEST="$HOME/Applications"
else DEST="/Applications"; fi

[ "$(uname -s)" = "Darwin" ] || { echo "Llasso runs on macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Llasso needs a Mac with Apple silicon."; exit 1; }
major=$(sw_vers -productVersion | cut -d . -f 1)
[ "$major" -ge 26 ] || { echo "Llasso needs macOS 26 or later. This Mac has $(sw_vers -productVersion)."; exit 1; }
mkdir -p "$DEST" 2>/dev/null || true
[ -w "$DEST" ] || { echo "This account cannot write to $DEST. Ask an administrator, or set LLASSO_INSTALL_DIR to a folder of your own."; exit 1; }

echo "Finding the latest Llasso..."
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"browser_download_url"' | grep 'mac-arm64\.zip"' | head -1 | cut -d '"' -f 4)
[ -n "$url" ] || { echo "No download was found. Get Llasso from https://github.com/$REPO/releases/latest"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "Downloading $(basename "$url")..."
curl -fL --progress-bar "$url" -o "$work/llasso.zip"
ditto -x -k "$work/llasso.zip" "$work"
[ -d "$work/Llasso.app" ] || { echo "The download held no Llasso.app."; exit 1; }

if pgrep -x Llasso >/dev/null 2>&1; then
  echo "Closing the Llasso that is open..."
  osascript -e 'tell application id "com.eqtr.llasso" to quit' >/dev/null 2>&1 || pkill -x Llasso || true
  sleep 2
fi

rm -rf "$DEST/Llasso.app"
ditto "$work/Llasso.app" "$DEST/Llasso.app"
xattr -dr com.apple.quarantine "$DEST/Llasso.app" 2>/dev/null || true

echo "Llasso is in $DEST. Opening it now."
echo "First run: paste an OpenRouter key in Settings, then allow Screen Recording, Microphone and Accessibility."
[ -n "$LLASSO_INSTALL_NO_OPEN" ] || open "$DEST/Llasso.app"
