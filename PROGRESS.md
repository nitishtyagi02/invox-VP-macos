# INVOX Virtual Printer — Progress Report & Technical Findings

**Date**: 2026-06-04  
**Status**: 🟡 Partially Working — Core issue identified, workaround needed

---

## Summary

The INVOX Virtual Printer Desktop Agent is a macOS application that intercepts print jobs and delivers them digitally to recipients. The goal is: User prints → popup asks for recipient (email/phone) → document gets delivered to their INVOX digital mailbox.

---

## What Works ✅

1. **CUPS Printer Installation** — "INVOX Digital Mailbox" printer registers and appears in macOS Print dialog
2. **Desktop Agent (Swift)** — Builds and runs successfully. Shows login window, authenticates with backend, monitors spool directory via `DispatchSource`, shows delivery popup with recipient/type/subject fields
3. **Delivery Popup** — Successfully triggers when a PDF appears in the watched spool directory
4. **Manual Test (curl)** — Agent's HTTP receiver on port 19283 correctly receives POST requests and triggers the popup
5. **Manual Test (file drop)** — Dropping a PDF into the spool directory triggers the popup
6. **CUPS Filter Execution** — Our custom filter (`invox-filter`) IS called by CUPS when printing to the INVOX printer
7. **CUPS Filter File Write** — The filter successfully wrote PDFs to `/private/var/spool/cups/tmp/` (confirmed for jobs 167-169)
8. **Backend API** — Spring Boot backend is running on localhost:8080

---

## The Core Problem ❌

**macOS CUPS Sandbox** prevents the filter/backend from:
- Writing to ANY user-accessible filesystem path (`/tmp`, `/usr/local/var/`, `~/Library/`)
- Making network calls (curl to localhost is blocked)
- The ONLY writable location is CUPS's own `$TMPDIR` = `/private/var/spool/cups/tmp/`

**BUT**: CUPS deletes files from its tmp directory immediately after the filter exits and the job completes.

**AND**: The user's agent process cannot read `/private/var/spool/cups/tmp/` (protected by SIP/permissions).

---

## Approaches Tried

| # | Approach | Result |
|---|----------|--------|
| 1 | Backend writes to `$HOME/Library/Application Support/INVOX/spool/` | ❌ CUPS runs as root, `$HOME=/var/root/` |
| 2 | Backend writes to user path via `dscl` resolution | ❌ Root can't write to user's `~/Library/` |
| 3 | Shared path `/usr/local/var/invox/spool/` | ❌ Sandbox: "Operation not permitted" |
| 4 | Shared path `/tmp/invox-spool/` | ❌ Sandbox blocks |
| 5 | Filter sends via `curl` to agent's HTTP port 19283 | ❌ Sandbox blocks network |
| 6 | Filter writes to CUPS `$TMPDIR` + bridge copies to user spool | ⚠️ Files written but CUPS deletes them before bridge can copy |
| 7 | Filter writes base64 to stderr (error_log) + bridge decodes | ❌ bash can't capture binary stdin into variable for base64 encoding |
| 8 | Filter uses temp file in TMPDIR for base64 | ❌ Temp file creation also blocked in newer filter invocations |
| 9 | Rapid-polling bridge (every 200ms) on CUPS tmp | ❌ Race condition — CUPS deletes too fast |

---

## What Actually Worked (Confirmed)

1. **Jobs 167-169**: The filter with `tee "$OUTPUT"` DID write to `/private/var/spool/cups/tmp/invox_*.pdf`. The bridge (at that time) successfully copied them to `/private/tmp/invox-spool/`. The agent detected them and **showed the popup**.

2. **HTTP Receiver**: When we manually sent `curl -X POST http://127.0.0.1:19283/print-job --data-binary "pdf"`, the popup appeared **instantly**.

---

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│  macOS App      │     │   CUPS Daemon         │     │  InvoxPrintAgent    │
│  (any app)      │────▶│   invox-filter        │────▶│  (Swift, menu bar)  │
│  Cmd+P → Print  │     │   writes PDF to       │     │  watches spool dir  │
└─────────────────┘     │   CUPS TMPDIR         │     │  shows popup        │
                        └──────────────────────┘     │  calls API          │
                                 │                    └─────────────────────┘
                                 ▼                              │
                        ┌──────────────────────┐               ▼
                        │  Bridge (root)        │     ┌─────────────────────┐
                        │  copies from CUPS tmp │     │  INVOX Backend      │
                        │  to user spool        │     │  localhost:8080     │
                        └──────────────────────┘     │  delivers document  │
                                                      └─────────────────────┘
```

---

## Files in Project

```
invox-VP-macos/
├── cups-backend/
│   ├── invox-printer       # CUPS backend script (legacy, not needed with filter approach)
│   ├── invox-filter        # CUPS filter — writes PDF to CUPS TMPDIR
│   ├── invox-bridge.sh     # Root helper — copies from CUPS tmp to user spool
│   └── INVOX.ppd           # Printer description file
├── InvoxPrintAgent/
│   └── Sources/InvoxPrintAgent/
│       ├── main.swift          # App entry, AppDelegate, menu bar, delegates
│       ├── SpoolWatcher.swift  # Watches spool dir via DispatchSource
│       ├── PrintJobReceiver.swift # HTTP listener on port 19283
│       ├── DeliveryPopup.swift # NSWindow popup (recipient, type, subject)
│       ├── LoginWindow.swift   # Login form (email/password)
│       ├── ApiClient.swift     # Calls backend API, token refresh
│       ├── KeychainHelper.swift # macOS Keychain storage
│       └── Config.swift        # Spool path, API URL, keychain keys
└── installer/
    ├── install.sh
    ├── uninstall.sh
    └── com.invox.printagent.plist
```

---

## Next Steps to Resolve

### Option A: Use `fswatch` with root privileges (Most Promising)
The bridge should use `fswatch` or `kqueue` on `/private/var/spool/cups/tmp/` to get **instant** notification when the file appears, and copy it BEFORE the filter exits (since CUPS only deletes after the filter returns). This requires the copy to happen while the filter is still running — which means the filter should `sleep 2` at the end to give the bridge time.

### Option B: Disable CUPS Sandbox (Simplest, requires SIP disable)
Disable macOS SIP, then the filter can write anywhere. Not recommended for production.

### Option C: Use a CUPS "notifier" instead of filter
CUPS supports notification subscriptions. The agent could subscribe to job events and fetch the document data via the CUPS API (`CUPS-Get-Document`).

### Option D: IPP virtual printer (No CUPS filter needed)
Implement a standalone IPP server that listens on a local port. Register it as a network printer. The IPP server receives print data directly in user space — no sandbox issues. This is the most robust long-term solution.

---

## Recommended Next Session Actions

1. **Quick fix**: Add `sleep 2` to the end of `invox-filter` (before `exit 0`) to keep the file alive in CUPS tmp long enough for the bridge to copy it
2. **Long-term**: Implement Option D (IPP virtual printer) — eliminates all sandbox issues
3. **Test the Send flow**: Once popup works reliably, test the full delivery to backend API and verify database entry

---

## Related Documents

- [Digital Mailbox Brainstorm Doc](./digital_mailbox_invitation_platform_full_brainstorm_doc.md) — Product vision, Virtual Printer is part of the "Digital Receipt & Invoice Mailbox" feature
- [Backend Docs](./invox/docs/) — API specs, feature backlog
- [Conversation Log](./conversation-log%20latest.text) — Full session history

---

## Key Learnings

1. macOS CUPS (since ~Ventura) runs filters/backends in a strict sandbox — cannot write outside CUPS dirs or make network calls
2. CUPS cleans up its tmp dir immediately after job completion
3. PPD-based drivers are deprecated but still work (with warning)
4. Raw queues are no longer supported on macOS
5. The `$2` argument in CUPS filter/backend is the username of the printing user
6. CUPS sets `TMPDIR=/private/var/spool/cups/tmp` for sandboxed processes
