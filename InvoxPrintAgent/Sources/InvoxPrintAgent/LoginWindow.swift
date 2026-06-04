import AppKit

protocol LoginWindowDelegate: AnyObject {
    func loginDidSucceed(companyName: String)
    func loginDidFail(error: String)
}

class LoginWindow: NSObject, NSWindowDelegate {
    weak var delegate: LoginWindowDelegate?
    private var window: NSWindow?
    private var emailField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var statusLabel: NSTextField!
    private var loginButton: NSButton!

    func show() {
        DispatchQueue.main.async { self.buildAndShowWindow() }
    }

    private func buildAndShowWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 380, height: 240)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window?.title = "INVOX — Partner Login"
        window?.delegate = self
        window?.level = .floating
        window?.center()

        let view = NSView(frame: contentRect)

        // Logo/title
        let titleLabel = NSTextField(labelWithString: "📬 INVOX Virtual Printer")
        titleLabel.frame = NSRect(x: 20, y: 200, width: 340, height: 22)
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.alignment = .center
        view.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Log in with your partner account")
        subtitleLabel.frame = NSRect(x: 20, y: 178, width: 340, height: 18)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        view.addSubview(subtitleLabel)

        // Email
        let emailLabel = NSTextField(labelWithString: "Email:")
        emailLabel.frame = NSRect(x: 20, y: 148, width: 340, height: 18)
        view.addSubview(emailLabel)

        emailField = NSTextField(frame: NSRect(x: 20, y: 124, width: 340, height: 24))
        emailField.placeholderString = "partner@company.com"
        view.addSubview(emailField)

        // Password
        let passLabel = NSTextField(labelWithString: "Password:")
        passLabel.frame = NSRect(x: 20, y: 96, width: 340, height: 18)
        view.addSubview(passLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 20, y: 72, width: 340, height: 24))
        view.addSubview(passwordField)

        // Status
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 48, width: 340, height: 18)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.alignment = .center
        view.addSubview(statusLabel)

        // Login button
        loginButton = NSButton(title: "Log In", target: self, action: #selector(loginClicked))
        loginButton.frame = NSRect(x: 140, y: 10, width: 100, height: 32)
        loginButton.bezelStyle = .rounded
        loginButton.keyEquivalent = "\r"
        view.addSubview(loginButton)

        window?.contentView = view
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func loginClicked() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !email.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = "Please enter email and password."
            return
        }
        loginButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Logging in..."

        performLogin(email: email, password: password)
    }

    private func performLogin(email: String, password: String) {
        let url = URL(string: "\(Config.apiBaseURL)/tenants/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["email": email, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.loginButton.isEnabled = true
                if let error = error {
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = "Connection failed: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = "Invalid response"
                    return
                }
                guard http.statusCode == 200 else {
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = "Invalid email or password."
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: String],
                      let accessToken = dataObj["accessToken"],
                      let refreshToken = dataObj["refreshToken"] else {
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = "Unexpected response format."
                    return
                }

                // Store tokens in Keychain
                KeychainHelper.save(key: Config.keychainAccountToken, value: accessToken)
                KeychainHelper.save(key: Config.keychainAccountRefresh, value: refreshToken)

                self?.window?.close()
                self?.fetchCompanyName()
            }
        }.resume()
    }

    private func fetchCompanyName() {
        guard let token = KeychainHelper.load(key: Config.keychainAccountToken) else {
            delegate?.loginDidSucceed(companyName: "Partner")
            return
        }
        let url = URL(string: "\(Config.apiBaseURL)/tenants/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var name = "Partner"
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let companyName = dataObj["companyName"] as? String {
                name = companyName
            }
            DispatchQueue.main.async { self?.delegate?.loginDidSucceed(companyName: name) }
        }.resume()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
