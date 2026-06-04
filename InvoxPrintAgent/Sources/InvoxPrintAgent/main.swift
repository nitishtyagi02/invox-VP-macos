import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, SpoolWatcherDelegate, DeliveryPopupDelegate {
    private let watcher = SpoolWatcher()
    private let apiClient = ApiClient()
    private var popup: DeliveryPopup?
    private var currentPDFPath: String?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        watcher.delegate = self
        watcher.start()
        print("[InvoxPrintAgent] Started. Waiting for print jobs...")
    }

    // MARK: - Menu Bar
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = "📬"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "INVOX Print Agent", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func quit() {
        watcher.stop()
        NSApp.terminate(nil)
    }

    // MARK: - SpoolWatcherDelegate
    func spoolWatcher(_ watcher: SpoolWatcher, didDetectNewPDF path: String, metadata: [String: String]) {
        currentPDFPath = path
        let title = metadata["title"] ?? URL(fileURLWithPath: path).lastPathComponent
        popup = DeliveryPopup()
        popup?.delegate = self
        popup?.show(documentTitle: title)
    }

    // MARK: - DeliveryPopupDelegate
    func popup(_ popup: DeliveryPopup, didSubmitRecipient recipient: String, type: String, subject: String?) {
        guard let pdfPath = currentPDFPath else { return }

        apiClient.deliver(pdfPath: pdfPath, recipient: recipient, documentType: type, subject: subject) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    self.showNotification(title: "Document Sent ✓",
                        body: resp.status == "DELIVERED"
                            ? "Delivered to \(recipient)"
                            : "Queued — invite sent to \(recipient)")
                    self.cleanupSpool(path: pdfPath)
                case .failure(let error):
                    self.showNotification(title: "Send Failed", body: error.localizedDescription)
                }
            }
        }
        currentPDFPath = nil
    }

    func popupDidCancel(_ popup: DeliveryPopup) {
        // Leave PDF in spool for next attempt
        currentPDFPath = nil
    }

    // MARK: - Helpers
    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func cleanupSpool(path: String) {
        try? FileManager.default.removeItem(atPath: path)
        let metaPath = path.replacingOccurrences(of: ".pdf", with: ".meta")
        try? FileManager.default.removeItem(atPath: metaPath)
    }
}

// MARK: - App entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only, no dock icon
app.run()
