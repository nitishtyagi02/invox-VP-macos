import AppKit

protocol DeliveryPopupDelegate: AnyObject {
    func popup(_ popup: DeliveryPopup, didSubmitRecipient recipient: String, type: String, subject: String?)
    func popupDidCancel(_ popup: DeliveryPopup)
}

class DeliveryPopup: NSObject, NSWindowDelegate {
    weak var delegate: DeliveryPopupDelegate?
    private var window: NSWindow?
    private var recipientField: NSTextField!
    private var typePopup: NSPopUpButton!
    private var subjectField: NSTextField!
    private var documentTitle: String = ""

    func show(documentTitle: String) {
        self.documentTitle = documentTitle
        DispatchQueue.main.async { self.buildAndShowWindow() }
    }

    private func buildAndShowWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 400, height: 260)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window?.title = "INVOX — Send Document"
        window?.delegate = self
        window?.level = .floating
        window?.center()

        let view = NSView(frame: contentRect)

        // Title label
        let titleLabel = NSTextField(labelWithString: "Send: \(documentTitle)")
        titleLabel.frame = NSRect(x: 20, y: 220, width: 360, height: 20)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        view.addSubview(titleLabel)

        // Recipient
        let recipientLabel = NSTextField(labelWithString: "Recipient (email or phone):")
        recipientLabel.frame = NSRect(x: 20, y: 185, width: 360, height: 18)
        view.addSubview(recipientLabel)

        recipientField = NSTextField(frame: NSRect(x: 20, y: 160, width: 360, height: 24))
        recipientField.placeholderString = "customer@email.com or +91xxxxxxxxxx"
        view.addSubview(recipientField)

        // Document type
        let typeLabel = NSTextField(labelWithString: "Document type:")
        typeLabel.frame = NSRect(x: 20, y: 125, width: 360, height: 18)
        view.addSubview(typeLabel)

        typePopup = NSPopUpButton(frame: NSRect(x: 20, y: 100, width: 360, height: 24))
        typePopup.addItems(withTitles: ["RECEIPT", "LETTER", "NOTICE", "OTHER"])
        view.addSubview(typePopup)

        // Subject (optional)
        let subjectLabel = NSTextField(labelWithString: "Subject (optional):")
        subjectLabel.frame = NSRect(x: 20, y: 70, width: 360, height: 18)
        view.addSubview(subjectLabel)

        subjectField = NSTextField(frame: NSRect(x: 20, y: 45, width: 360, height: 24))
        subjectField.placeholderString = "Auto-generated if empty"
        view.addSubview(subjectField)

        // Buttons
        let sendButton = NSButton(title: "Send", target: self, action: #selector(sendClicked))
        sendButton.frame = NSRect(x: 280, y: 10, width: 100, height: 30)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        view.addSubview(sendButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: 170, y: 10, width: 100, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        view.addSubview(cancelButton)

        window?.contentView = view
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sendClicked() {
        let recipient = recipientField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty else {
            NSSound.beep()
            return
        }
        let type = typePopup.titleOfSelectedItem ?? "OTHER"
        let subject = subjectField.stringValue.isEmpty ? nil : subjectField.stringValue
        window?.close()
        delegate?.popup(self, didSubmitRecipient: recipient, type: type, subject: subject)
    }

    @objc private func cancelClicked() {
        window?.close()
        delegate?.popupDidCancel(self)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
