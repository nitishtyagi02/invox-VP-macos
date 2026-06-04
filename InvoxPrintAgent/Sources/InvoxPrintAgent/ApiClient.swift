import Foundation

class ApiClient {
    private let baseURL: String

    init(baseURL: String = Config.apiBaseURL) {
        self.baseURL = baseURL
    }

    /// Refresh the access token using the stored refresh token
    func refreshToken(completion: @escaping (Bool) -> Void) {
        guard let refreshToken = KeychainHelper.load(key: Config.keychainAccountRefresh) else {
            completion(false)
            return
        }
        let url = URL(string: "\(baseURL)/tenants/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: String],
                  let newAccess = dataObj["accessToken"],
                  let newRefresh = dataObj["refreshToken"] else {
                completion(false)
                return
            }
            KeychainHelper.save(key: Config.keychainAccountToken, value: newAccess)
            KeychainHelper.save(key: Config.keychainAccountRefresh, value: newRefresh)
            completion(true)
        }.resume()
    }

    func deliver(pdfPath: String, recipient: String, documentType: String, subject: String?,
                 completion: @escaping (Result<DeliveryResponse, Error>) -> Void) {
        deliverInternal(pdfPath: pdfPath, recipient: recipient, documentType: documentType, subject: subject, retried: false, completion: completion)
    }

    private func deliverInternal(pdfPath: String, recipient: String, documentType: String, subject: String?,
                                 retried: Bool, completion: @escaping (Result<DeliveryResponse, Error>) -> Void) {
        guard let token = KeychainHelper.load(key: Config.keychainAccountToken) else {
            completion(.failure(ApiError.notAuthenticated))
            return
        }

        let url = URL(string: "\(baseURL)/tenants/me/print-deliver")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // recipient
        body.appendFormField(name: "recipient", value: recipient, boundary: boundary)
        // documentType
        body.appendFormField(name: "documentType", value: documentType, boundary: boundary)
        // subject (optional)
        if let subject = subject, !subject.isEmpty {
            body.appendFormField(name: "subject", value: subject, boundary: boundary)
        }
        // file
        let pdfData = try! Data(contentsOf: URL(fileURLWithPath: pdfPath))
        let filename = URL(fileURLWithPath: pdfPath).lastPathComponent
        body.appendFileField(name: "file", filename: filename, mimeType: "application/pdf", data: pdfData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(ApiError.invalidResponse))
                return
            }
            if http.statusCode == 401 && !retried {
                // Try refresh and retry once
                self?.refreshToken { success in
                    if success {
                        self?.deliverInternal(pdfPath: pdfPath, recipient: recipient, documentType: documentType, subject: subject, retried: true, completion: completion)
                    } else {
                        completion(.failure(ApiError.notAuthenticated))
                    }
                }
                return
            }
            if http.statusCode == 401 {
                completion(.failure(ApiError.notAuthenticated))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                completion(.failure(ApiError.serverError(http.statusCode, msg)))
                return
            }
            if let resp = try? JSONDecoder().decode(ApiWrapper<DeliveryResponse>.self, from: data) {
                completion(.success(resp.data))
            } else {
                completion(.failure(ApiError.invalidResponse))
            }
        }.resume()
    }
}

// MARK: - Models
struct DeliveryResponse: Decodable {
    let id: String
    let status: String
    let recipient: String
}

struct ApiWrapper<T: Decodable>: Decodable {
    let data: T
    let message: String?
}

enum ApiError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated. Please log in."
        case .invalidResponse: return "Invalid response from server."
        case .serverError(let code, let msg): return "Server error \(code): \(msg)"
        }
    }
}

// MARK: - Multipart helpers
extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFileField(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
