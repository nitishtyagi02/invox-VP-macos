import Foundation

enum Config {
    static let spoolDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/INVOX/spool"
    }()

    static let apiBaseURL = "http://localhost:8080/api/v1"
    static let keychainService = "com.invox.printagent"
    static let keychainAccountToken = "access_token"
    static let keychainAccountRefresh = "refresh_token"
}
