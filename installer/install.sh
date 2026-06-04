#!/bin/bash
# INVOX Virtual Printer — macOS Installer
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== INVOX Virtual Printer Installer ==="

# 1. Build the Swift agent
echo "[1/4] Building Desktop Agent..."
cd "$PROJECT_DIR/InvoxPrintAgent"
swift build -c release
AGENT_BIN="$PROJECT_DIR/InvoxPrintAgent/.build/release/InvoxPrintAgent"

# 2. Install agent binary
echo "[2/4] Installing agent to /usr/local/bin..."
sudo cp "$AGENT_BIN" /usr/local/bin/InvoxPrintAgent
sudo chmod 755 /usr/local/bin/InvoxPrintAgent

# 3. Install CUPS backend and register printer
echo "[3/4] Installing CUPS backend and registering printer..."
sudo cp "$PROJECT_DIR/cups-backend/invox-printer" /usr/libexec/cups/backend/invox
sudo chmod 755 /usr/libexec/cups/backend/invox
sudo lpadmin -p "INVOX-Digital-Mailbox" -v "invox:/" -E -m "raw" -D "INVOX Digital Mailbox" -L "Send to INVOX"

# 4. Install and load LaunchAgent
echo "[4/4] Installing LaunchAgent..."
cp "$SCRIPT_DIR/com.invox.printagent.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.invox.printagent.plist

echo ""
echo "✅ INVOX Virtual Printer installed!"
echo "   Printer: 'INVOX Digital Mailbox' is now in your printer list."
echo "   Agent: Running in background (menu bar 📬 icon)."
echo ""
echo "Next: Print from any app → select 'INVOX Digital Mailbox' → enter recipient → done."
