# INVOX Virtual Printer — macOS

A virtual printer that captures print output from any application and delivers it as a PDF to a recipient's INVOX digital mailbox.

## Architecture

```
┌──────────────┐     ┌────────────────┐     ┌──────────────────┐     ┌────────────┐
│ Any App      │────▶│ CUPS Backend   │────▶│ Desktop Agent    │────▶│ INVOX API  │
│ (Print Cmd)  │     │ (invox-printer)│     │ (Swift/AppKit)   │     │ /print-    │
└──────────────┘     │ Outputs PDF to │     │ - Monitors spool │     │  deliver   │
                     │ spool directory│     │ - Shows popup    │     └────────────┘
                     └────────────────┘     │ - Uploads PDF    │
                                            │ - Toast confirm  │
                                            └──────────────────┘
```

## Components

### 1. CUPS Backend (`cups-backend/invox-printer`)
- Registers as a printer in macOS System Preferences
- Receives PostScript/PDF from print subsystem
- Converts to PDF (via `pstopdf` if needed) and writes to spool directory

### 2. Desktop Agent (`InvoxPrintAgent/`)
- Swift/AppKit application running as LaunchAgent
- Monitors spool directory via FSEvents
- On new PDF: shows popup window (recipient + document type)
- Calls `POST /api/v1/tenants/me/print-deliver` with PDF + metadata
- Stores auth token in macOS Keychain
- Offline queue with retry (SQLite)
- Toast notification on success/failure

### 3. Installer (`installer/`)
- Registers CUPS printer
- Installs LaunchAgent plist
- First-run: opens browser for partner login → stores token

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+ (for building Swift agent)
- CUPS (pre-installed on macOS)

## Quick Setup (Development)

```bash
# 1. Install CUPS backend
sudo cp cups-backend/invox-printer /usr/libexec/cups/backend/invox
sudo chmod 755 /usr/libexec/cups/backend/invox

# 2. Register printer
lpadmin -p "INVOX-Digital-Mailbox" -v "invox:/" -E -m "raw"

# 3. Build and run agent
cd InvoxPrintAgent
swift build
.build/debug/InvoxPrintAgent

# 4. Test: print from any app → select "INVOX Digital Mailbox" printer
```

## API Integration

The agent calls:
```
POST /api/v1/tenants/me/print-deliver
Content-Type: multipart/form-data

- recipient: email or phone
- documentType: RECEIPT | LETTER | NOTICE | OTHER
- subject: (optional)
- file: PDF binary
```

Auth: `Authorization: Bearer <tenant_access_token>` (stored in Keychain, refreshable)

## Directory Structure

```
invox-VP-macos/
├── README.md
├── cups-backend/
│   └── invox-printer          # CUPS backend script
├── InvoxPrintAgent/
│   ├── Package.swift          # Swift Package Manager
│   └── Sources/
│       └── InvoxPrintAgent/
│           ├── main.swift             # Entry point
│           ├── SpoolWatcher.swift     # FSEvents directory monitor
│           ├── DeliveryPopup.swift    # AppKit popup window
│           ├── ApiClient.swift        # INVOX API calls
│           ├── KeychainHelper.swift   # Secure token storage
│           ├── OfflineQueue.swift     # SQLite offline queue
│           └── Config.swift           # Configuration
├── installer/
│   ├── install.sh             # Dev install script
│   ├── uninstall.sh           # Cleanup script
│   └── com.invox.printagent.plist  # LaunchAgent
└── .gitignore
```
