import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, DeliveryPopupDelegate, LoginWindowDelegate {
    private let ippServer = IPPServer()
    private let apiClient = ApiClient()
    private var popup: DeliveryPopup?
    private var loginWindow: LoginWindow?
    private var currentPDFPath: String?
    private var statusItem: NSStatusItem?
    private var companyName: String = "INVOX"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Always start IPP server (printer needs it even before login)
        ippServer.onJobReceived = { [weak self] pdfPath, title in
            self?.handlePrintJob(pdfPath: pdfPath, title: title)
        }
        ippServer.start()

        if KeychainHelper.load(key: Config.keychainAccountToken) != nil {
            onReady()
        } else {
            showLogin()
        }
    }

    private func showLogin() {
        loginWindow = LoginWindow()
        loginWindow?.delegate = self
        loginWindow?.show()
    }

    private func onReady() {
        print("[InvoxPrintAgent] Authenticated as \(companyName). Waiting for print jobs on port \(Config.ippPort)...")
    }

    // MARK: - Print Job Handler
    private func handlePrintJob(pdfPath: String, title: String) {
        currentPDFPath = pdfPath
        popup = DeliveryPopup()
        popup?.delegate = self
        popup?.show(documentTitle: title)
    }

    // MARK: - LoginWindowDelegate
    func loginDidSucceed(companyName: String) {
        self.companyName = companyName
        loginWindow = nil
        updateMenuTitle()
        onReady()
        showNotification(title: "INVOX Ready", body: "Logged in as \(companyName). Print to send documents.")
    }

    func loginDidFail(error: String) {
        showNotification(title: "Login Failed", body: error)
    }

    // MARK: - Menu Bar
    private func setupMenuBar() {
        // Enable copy/paste by adding Edit menu
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = "📬"
        }
        updateMenuTitle()
    }

    private func updateMenuTitle() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "INVOX — \(companyName)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Log Out", action: #selector(logout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func logout() {
        KeychainHelper.delete(key: Config.keychainAccountToken)
        KeychainHelper.delete(key: Config.keychainAccountRefresh)
        companyName = "INVOX"
        updateMenuTitle()
        showLogin()
    }

    @objc private func quit() {
        ippServer.stop()
        NSApp.terminate(nil)
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
                    if case ApiError.notAuthenticated = error {
                        self.showNotification(title: "Session Expired", body: "Please log in again.")
                        self.logout()
                    } else {
                        self.showNotification(title: "Send Failed", body: error.localizedDescription)
                    }
                }
            }
        }
        currentPDFPath = nil
    }

    func popupDidCancel(_ popup: DeliveryPopup) {
        currentPDFPath = nil
    }

    // MARK: - Helpers
    private func showNotification(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func cleanupSpool(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - App entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
