#!/bin/zsh
set -euo pipefail

# Install script for daily-shutdown
# 1. Compiles the Swift source
# 2. Installs the binary into ~/bin (or /User/$USER/bin if that unusual path exists)
# 3. Installs & (re)loads the LaunchAgent so it starts after login

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC_FILE="daily-shutdown.swift"
BIN_NAME="daily-shutdown"

# Determine install directory.
if [ -d "/User/$USER/bin" ]; then
  INSTALL_DIR="/User/$USER/bin"
else
  INSTALL_DIR="$HOME/bin"
fi

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.example.daily-shutdown"
PLIST_PATH="$PLIST_DIR/${PLIST_LABEL}.plist"

echo "==> Using install dir: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$PLIST_DIR"

# Check swift compiler availability
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc not found in PATH. Install Xcode Command Line Tools (xcode-select --install)." >&2
  exit 1
fi

# Ensure source exists
if [ ! -f "$SCRIPT_DIR/$SRC_FILE" ]; then
  echo "Error: $SRC_FILE not found alongside install script at $SCRIPT_DIR" >&2
  exit 1
fi

echo "==> Compiling $SRC_FILE"
swiftc -O "$SCRIPT_DIR/$SRC_FILE" -o "$INSTALL_DIR/$BIN_NAME"

chmod 755 "$INSTALL_DIR/$BIN_NAME"

echo "==> Writing LaunchAgent plist: $PLIST_PATH"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>                 <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/${BIN_NAME}</string>
  </array>
  <key>RunAtLoad</key>             <true/>
  <key>KeepAlive</key>             <false/>
  <key>ProcessType</key>           <string>Interactive</string>
  <key>StandardOutPath</key>       <string>/tmp/${BIN_NAME}.out.log</string>
  <key>StandardErrorPath</key>     <string>/tmp/${BIN_NAME}.err.log</string>
</dict>
</plist>
EOF

echo "==> (Re)loading LaunchAgent"
# Attempt to unload previous instance (ignore errors)
if launchctl print gui/$(id -u)/"${PLIST_LABEL}" >/dev/null 2>&1; then
  launchctl bootout gui/$(id -u) "$PLIST_PATH" || true
fi
launchctl bootstrap gui/$(id -u) "$PLIST_PATH"

echo "==> Loaded. Verifying:"
launchctl print gui/$(id -u)/"${PLIST_LABEL}" >/dev/null 2>&1 && echo "LaunchAgent is active."

echo "==> Done."
echo "Logs: tail -f /tmp/${BIN_NAME}.out.log /tmp/${BIN_NAME}.err.log"
echo "To remove:"
echo "  launchctl bootout gui/\$(id -u) \"$PLIST_PATH\" && rm -f \"$PLIST_PATH\" \"$INSTALL_DIR/$BIN_NAME\""
