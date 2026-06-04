#!/bin/bash
# INVOX Virtual Printer — macOS Uninstaller
set -e

echo "=== INVOX Virtual Printer Uninstaller ==="

# Stop agent
launchctl unload ~/Library/LaunchAgents/com.invox.printagent.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.invox.printagent.plist

# Remove printer
sudo lpadmin -x "INVOX-Digital-Mailbox" 2>/dev/null || true

# Remove files
sudo rm -f /usr/libexec/cups/backend/invox
sudo rm -f /usr/local/bin/InvoxPrintAgent

echo "✅ INVOX Virtual Printer uninstalled."
