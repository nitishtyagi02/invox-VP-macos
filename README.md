# INVOX Virtual Printer — macOS Desktop Agent

A macOS application that adds an "INVOX Digital Mailbox" virtual printer to your system. Print from any app to send documents (receipts, invoices, letters) directly to a recipient's INVOX digital mailbox.

## How It Works

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────────┐
│  Any macOS App  │      │   macOS CUPS     │      │  INVOX Print Agent  │
│  (Cmd+P)        │─────▶│   IPP Backend    │─────▶│  (IPP Server :63140)│
│                 │      │                  │      │  Shows popup        │
└─────────────────┘      └──────────────────┘      │  Calls API          │
                                                    └─────────┬───────────┘
                                                              │
                                                              ▼
                                                    ┌─────────────────────┐
                                                    │  INVOX Backend API  │
                                                    │  Delivers document  │
                                                    │  to recipient       │
                                                    └─────────────────────┘
```

1. User prints from any app → selects "INVOX Digital Mailbox" printer
2. CUPS sends the print job via IPP to the agent (localhost:63140)
3. Agent shows a popup asking for recipient (email/phone) and document type
4. Agent uploads the PDF to the INVOX backend API
5. Backend delivers to the recipient's digital mailbox (or sends an invite if not registered)

## Installation

### From .pkg installer

```bash
# Build the installer
bash installer/build-pkg.sh

# Install
open dist/InvoxPrintAgent-1.0.0.pkg
```

The installer:
- Installs the app to `/Applications/INVOX Print Agent.app`
- Registers the virtual printer with CUPS
- Sets up auto-start on login (LaunchAgent)

### Manual (Development)

```bash
# 1. Build and run the agent
cd InvoxPrintAgent
swift run

# 2. Register the printer (while agent is running)
sudo lpadmin -p "INVOX-Digital-Mailbox" \
    -v "ipp://127.0.0.1:63140/" -E \
    -P "../cups-backend/INVOX-IPP.ppd" \
    -D "INVOX Digital Mailbox"

# 3. Remove cupsFilter line from installed PPD
sudo sed -i '' '/*cupsFilter/d' /private/etc/cups/ppd/INVOX-Digital-Mailbox.ppd
```

## Usage

1. The agent runs in the menu bar (📬 icon)
2. First launch shows a login window — enter your partner credentials
3. Print from any app → Cmd+P → select "INVOX Digital Mailbox"
4. A popup appears asking for:
   - Recipient (email or phone)
   - Document type (Receipt, Letter, Notice, Other)
   - Subject (optional)
5. Click Send — document is delivered to the recipient

## Project Structure

```
invox-VP-macos/
├── InvoxPrintAgent/           # Swift macOS app
│   ├── Package.swift
│   └── Sources/InvoxPrintAgent/
│       ├── main.swift          # AppDelegate, menu bar, popup coordination
│       ├── IPPServer.swift     # Minimal IPP server (receives print jobs)
│       ├── DeliveryPopup.swift # Recipient input popup window
│       ├── LoginWindow.swift   # Partner login form
│       ├── ApiClient.swift     # Backend API (deliver, auth, refresh)
│       ├── KeychainHelper.swift# macOS Keychain for token storage
│       ├── Config.swift        # Port, API URL, paths
│       ├── SpoolWatcher.swift  # (legacy) filesystem watcher
│       └── PrintJobReceiver.swift # (legacy) HTTP receiver
├── cups-backend/
│   ├── INVOX-IPP.ppd          # Printer description for CUPS
│   ├── invox-filter            # (legacy) CUPS filter approach
│   ├── invox-printer           # (legacy) CUPS backend approach
│   └── invox-bridge.sh         # (legacy) root bridge script
├── installer/
│   ├── build-pkg.sh           # Build script → produces .pkg
│   ├── postinstall            # Runs after .pkg install
│   ├── com.invox.printagent.plist  # LaunchAgent for auto-start
│   ├── install.sh             # (legacy) manual install
│   └── uninstall.sh           # Uninstall script
├── dist/                      # Build output (.app, .pkg)
├── PROGRESS.md                # Technical findings & history
└── README.md                  # This file
```

## Configuration

Edit `Sources/InvoxPrintAgent/Config.swift`:

| Setting | Default | Description |
|---------|---------|-------------|
| `apiBaseURL` | `http://localhost:8080/api/v1` | INVOX backend URL |
| `ippPort` | `63140` | IPP server port |
| `spoolDirectory` | `~/Library/Application Support/INVOX/spool` | PDF storage |

## Building

```bash
# Debug build
cd InvoxPrintAgent && swift build

# Release build
cd InvoxPrintAgent && swift build -c release

# Build .pkg installer
bash installer/build-pkg.sh
```

## Uninstall

```bash
# Remove printer
sudo lpadmin -x INVOX-Digital-Mailbox

# Remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.invox.printagent.plist
rm ~/Library/LaunchAgents/com.invox.printagent.plist

# Remove app
rm -rf "/Applications/INVOX Print Agent.app"
```

## Technical Notes

- **IPP approach**: The agent runs a minimal IPP 1.1 server. CUPS treats it as a network printer and sends jobs directly — no sandbox restrictions.
- **Previous approaches** (CUPS filter, backend script, bridge) were blocked by macOS CUPS sandbox which prevents filters/backends from writing to user-accessible paths or making network calls.
- **Chunked encoding**: CUPS sends print data using HTTP/1.1 chunked transfer encoding. The IPP server decodes this before extracting the PDF.
- **PPD**: Required by CUPS to register the printer. Uses `cupsFilter2` for PDF passthrough (removed post-install to avoid filter chain).
- **Auto-start**: LaunchAgent starts the agent on login. The printer only works while the agent is running.

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- INVOX backend running (for document delivery)
