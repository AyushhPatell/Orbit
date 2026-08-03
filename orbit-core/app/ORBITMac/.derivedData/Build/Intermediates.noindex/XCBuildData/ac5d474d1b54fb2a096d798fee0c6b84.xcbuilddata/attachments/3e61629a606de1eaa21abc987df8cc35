#!/bin/sh
# Copy Homebrew blueutil next to ORBITMac so the sandbox can execute it; re-sign for the app identity.
set -e
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/blueutil"
SRC=""
for C in /opt/homebrew/bin/blueutil /usr/local/bin/blueutil; do
  if [ -x "$C" ]; then SRC="$C"; break; fi
done
if [ -n "$SRC" ]; then
  cp -f "$SRC" "$DEST"
  chmod +x "$DEST"
  codesign --force --sign - "$DEST" 2>/dev/null || true
  echo "[ORBITMac] Copied blueutil from $SRC"
else
  echo "[ORBITMac] blueutil not found at Homebrew paths; install with: brew install blueutil"
fi

