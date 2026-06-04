import Foundation

/// Minimal IPP server that receives print jobs on a local port.
/// CUPS sends jobs to this as if it were a network printer — no sandbox issues.
class IPPServer {
    private var serverSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    let port: UInt16 = 63140  // High port, no root needed
    var onJobReceived: ((String, String) -> Void)?  // (pdfPath, title)

    func start() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { print("[IPP] socket() failed"); return }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { print("[IPP] bind() failed: \(errno)"); close(serverSocket); return }
        guard listen(serverSocket, 5) == 0 else { print("[IPP] listen() failed"); close(serverSocket); return }

        listenSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global())
        listenSource?.setEventHandler { [weak self] in self?.acceptConnection() }
        listenSource?.setCancelHandler { [weak self] in if let s = self?.serverSocket, s >= 0 { close(s) } }
        listenSource?.resume()
        print("[IPP] Listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverSocket, $0, &len) }
        }
        guard clientFd >= 0 else { return }
        DispatchQueue.global().async { [weak self] in self?.handleConnection(fd: clientFd) }
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }

        // Read HTTP headers
        var totalData = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { buf.deallocate() }

        // Read until we have the full header
        while true {
            let n = read(fd, buf, 65536)
            if n <= 0 { break }
            totalData.append(buf, count: n)
            if totalData.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if totalData.count > 16384 { break }
        }

        guard let headerEnd = totalData.range(of: Data("\r\n\r\n".utf8)) else {
            let resp = buildIPPResponse(requestId: 0, statusCode: 0x0000, jobId: 0)
            sendHTTPResponse(fd: fd, body: resp)
            return
        }

        let headerStr = String(data: totalData[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var contentLength = -1
        var isChunked = false
        for line in headerStr.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            if lower.contains("transfer-encoding") && lower.contains("chunked") {
                isChunked = true
            }
        }

        // Read body
        var body = Data(totalData[headerEnd.upperBound...])

        if isChunked {
            // Read all chunked data
            while true {
                let n = read(fd, buf, 65536)
                if n <= 0 { break }
                body.append(buf, count: n)
                // Check for end of chunked: "0\r\n\r\n"
                if body.count > 5 && body.suffix(5) == Data("0\r\n\r\n".utf8) { break }
                if body.count > 7 && body.suffix(7) == Data("\r\n0\r\n\r\n".utf8) { break }
            }
            // Decode chunked encoding
            body = decodeChunked(body)
        } else if contentLength > 0 {
            while body.count < contentLength {
                let n = read(fd, buf, min(65536, contentLength - body.count))
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }

        processIPPRequest(fd: fd, body: body)
    }

    private func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        var pos = data.startIndex

        while pos < data.endIndex {
            // Find chunk size line
            guard let lineEnd = data[pos...].range(of: Data("\r\n".utf8)) else { break }
            let sizeStr = String(data: data[pos..<lineEnd.lowerBound], encoding: .ascii) ?? "0"
            guard let chunkSize = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), chunkSize > 0 else { break }

            let chunkStart = lineEnd.upperBound
            let chunkEnd = data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            result.append(data[chunkStart..<chunkEnd])
            pos = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex // skip \r\n after chunk
        }
        return result
    }

    private func processIPPRequest(fd: Int32, body: Data) {
        guard body.count >= 8 else {
            let resp = buildIPPResponse(requestId: 0, statusCode: 0x0000, jobId: 0)
            sendHTTPResponse(fd: fd, body: resp)
            return
        }

        let (operationId, requestId, title) = parseIPPHeader(body)
        print("[IPP] Operation: 0x\(String(operationId, radix: 16)) reqId:\(requestId) size:\(body.count)")

        switch operationId {
        case 0x0002: // Print-Job
            let pdfPath = extractAndSavePDF(from: body)
            let ippResponse = buildIPPResponse(requestId: requestId, statusCode: 0x0000, jobId: Int(Date().timeIntervalSince1970) % 100000)
            sendHTTPResponse(fd: fd, body: ippResponse)
            if let path = pdfPath {
                let safePath = String(path)
                let safeTitle = String(title)
                DispatchQueue.main.async { [weak self] in
                    self?.onJobReceived?(safePath, safeTitle)
                }
            }

        case 0x000B: // Get-Printer-Attributes
            let ippResponse = buildGetPrinterAttributesResponse(requestId: requestId)
            sendHTTPResponse(fd: fd, body: ippResponse)

        case 0x0004: // Validate-Job
            let ippResponse = buildIPPResponse(requestId: requestId, statusCode: 0x0000, jobId: 0)
            sendHTTPResponse(fd: fd, body: ippResponse)

        case 0x0009: // Get-Jobs
            let ippResponse = buildIPPResponse(requestId: requestId, statusCode: 0x0000, jobId: 0)
            sendHTTPResponse(fd: fd, body: ippResponse)

        default:
            // Return successful-ok for anything else
            let ippResponse = buildIPPResponse(requestId: requestId, statusCode: 0x0000, jobId: 0)
            sendHTTPResponse(fd: fd, body: ippResponse)
        }
    }

    // MARK: - IPP Parsing

    private func parseIPPHeader(_ data: Data) -> (UInt16, Int32, String) {
        guard data.count >= 8 else { return (0, 0, "Print Job") }
        let opHi = UInt16(data[2]) << 8 | UInt16(data[3])
        let reqId = Int32(data[4]) << 24 | Int32(data[5]) << 16 | Int32(data[6]) << 8 | Int32(data[7])
        let title = extractAttribute(from: data, name: "job-name") ?? "Print Job"
        return (opHi, reqId, title)
    }

    private func extractAttribute(from data: Data, name: String) -> String? {
        // Search for the attribute name in IPP attributes
        let nameData = Data(name.utf8)
        var i = 8 // Skip IPP header

        while i < data.count - 4 {
            let tag = data[i]
            i += 1

            if tag == 0x03 { break } // end-of-attributes
            if tag < 0x10 { continue } // group tag

            guard i + 2 <= data.count else { break }
            let nameLen = Int(data[i]) << 8 | Int(data[i+1])
            i += 2

            guard i + nameLen <= data.count else { break }
            let attrName = Data(data[i..<i+nameLen])
            i += nameLen

            guard i + 2 <= data.count else { break }
            let valLen = Int(data[i]) << 8 | Int(data[i+1])
            i += 2

            guard i + valLen <= data.count else { break }
            if attrName == nameData {
                return String(data: data[i..<i+valLen], encoding: .utf8)
            }
            i += valLen
        }
        return nil
    }

    private func extractAndSavePDF(from data: Data) -> String? {
        // Find PDF data after IPP attributes (look for %PDF marker)
        guard let range = data.range(of: Data("%PDF".utf8)) else {
            // If no %PDF marker, save everything after end-of-attributes tag (0x03)
            if let endIdx = data.firstIndex(of: 0x03), endIdx < data.count - 1 {
                let pdfData = data[(data.index(after: endIdx))...]
                return savePDF(Data(pdfData))
            }
            return nil
        }
        let pdfData = data[range.lowerBound...]
        return savePDF(Data(pdfData))
    }

    private func savePDF(_ data: Data) -> String? {
        guard data.count > 0 else { return nil }
        let spoolDir = Config.spoolDirectory
        try? FileManager.default.createDirectory(atPath: spoolDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "\(spoolDir)/invox_\(timestamp).pdf"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            print("[IPP] Failed to save PDF: \(error)")
            return nil
        }
    }

    // MARK: - IPP Response Building

    private func buildIPPResponse(requestId: Int32, statusCode: UInt16, jobId: Int) -> Data {
        var resp = Data()
        // Version 1.1
        resp.append(contentsOf: [0x01, 0x01])
        // Status code
        resp.append(UInt8(statusCode >> 8))
        resp.append(UInt8(statusCode & 0xFF))
        // Request ID
        resp.append(UInt8((requestId >> 24) & 0xFF))
        resp.append(UInt8((requestId >> 16) & 0xFF))
        resp.append(UInt8((requestId >> 8) & 0xFF))
        resp.append(UInt8(requestId & 0xFF))

        // Operation attributes group
        resp.append(0x01)
        appendIPPAttribute(&resp, tag: 0x47, name: "attributes-charset", value: "utf-8")
        appendIPPAttribute(&resp, tag: 0x48, name: "attributes-natural-language", value: "en")

        if jobId > 0 {
            // Job attributes group
            resp.append(0x02)
            appendIPPIntAttribute(&resp, name: "job-id", value: Int32(jobId))
            appendIPPAttribute(&resp, tag: 0x45, name: "job-uri", value: "ipp://127.0.0.1:\(port)/jobs/\(jobId)")
            appendIPPAttribute(&resp, tag: 0x23, name: "job-state", value: nil, intValue: 9) // completed
        }

        // End of attributes
        resp.append(0x03)
        return resp
    }

    private func buildGetPrinterAttributesResponse(requestId: Int32) -> Data {
        var resp = Data()
        resp.append(contentsOf: [0x01, 0x01]) // Version 1.1
        resp.append(contentsOf: [0x00, 0x00]) // successful-ok
        resp.append(UInt8((requestId >> 24) & 0xFF))
        resp.append(UInt8((requestId >> 16) & 0xFF))
        resp.append(UInt8((requestId >> 8) & 0xFF))
        resp.append(UInt8(requestId & 0xFF))

        // Operation attributes
        resp.append(0x01)
        appendIPPAttribute(&resp, tag: 0x47, name: "attributes-charset", value: "utf-8")
        appendIPPAttribute(&resp, tag: 0x48, name: "attributes-natural-language", value: "en")

        // Printer attributes
        resp.append(0x04)
        appendIPPAttribute(&resp, tag: 0x45, name: "printer-uri-supported", value: "ipp://127.0.0.1:\(port)/")
        appendIPPAttribute(&resp, tag: 0x44, name: "uri-authentication-supported", value: "none")
        appendIPPAttribute(&resp, tag: 0x44, name: "uri-security-supported", value: "none")
        appendIPPAttribute(&resp, tag: 0x42, name: "printer-name", value: "INVOX Digital Mailbox")
        appendIPPAttribute(&resp, tag: 0x23, name: "printer-state", value: nil, intValue: 3) // idle
        appendIPPAttribute(&resp, tag: 0x44, name: "printer-state-reasons", value: "none")
        appendIPPAttribute(&resp, tag: 0x49, name: "document-format-supported", value: "application/pdf")
        appendIPPBoolAttribute(&resp, name: "printer-is-accepting-jobs", value: true)
        appendIPPAttribute(&resp, tag: 0x44, name: "ipp-versions-supported", value: "1.1")
        // operations-supported (multiple integer values)
        appendIPPIntAttribute(&resp, name: "operations-supported", value: 0x0002) // Print-Job
        appendIPPIntNoName(&resp, value: 0x0004) // Validate-Job
        appendIPPIntNoName(&resp, value: 0x0008) // Cancel-Job
        appendIPPIntNoName(&resp, value: 0x0009) // Get-Jobs
        appendIPPIntNoName(&resp, value: 0x000B) // Get-Printer-Attributes
        appendIPPAttribute(&resp, tag: 0x47, name: "charset-supported", value: "utf-8")
        appendIPPAttribute(&resp, tag: 0x48, name: "natural-language-configured", value: "en")
        appendIPPAttribute(&resp, tag: 0x44, name: "compression-supported", value: "none")
        appendIPPAttribute(&resp, tag: 0x49, name: "document-format-default", value: "application/pdf")
        appendIPPAttribute(&resp, tag: 0x44, name: "pdl-override-supported", value: "not-attempted")

        resp.append(0x03) // end
        return resp
    }

    private func appendIPPAttribute(_ data: inout Data, tag: UInt8, name: String, value: String?, intValue: Int32 = 0) {
        data.append(tag)
        let nameBytes = Data(name.utf8)
        data.append(UInt8(nameBytes.count >> 8))
        data.append(UInt8(nameBytes.count & 0xFF))
        data.append(nameBytes)

        if let val = value {
            let valBytes = Data(val.utf8)
            data.append(UInt8(valBytes.count >> 8))
            data.append(UInt8(valBytes.count & 0xFF))
            data.append(valBytes)
        } else {
            data.append(contentsOf: [0x00, 0x04])
            data.append(UInt8((intValue >> 24) & 0xFF))
            data.append(UInt8((intValue >> 16) & 0xFF))
            data.append(UInt8((intValue >> 8) & 0xFF))
            data.append(UInt8(intValue & 0xFF))
        }
    }

    private func appendIPPIntAttribute(_ data: inout Data, name: String, value: Int32) {
        appendIPPAttribute(&data, tag: 0x21, name: name, value: nil, intValue: value)
    }

    private func appendIPPIntNoName(_ data: inout Data, value: Int32) {
        // Additional value in a 1setOf — same tag, zero-length name
        data.append(0x21) // integer tag
        data.append(contentsOf: [0x00, 0x00]) // name length = 0
        data.append(contentsOf: [0x00, 0x04]) // value length = 4
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendIPPBoolAttribute(_ data: inout Data, name: String, value: Bool) {
        data.append(0x22) // boolean tag
        let nameBytes = Data(name.utf8)
        data.append(UInt8(nameBytes.count >> 8))
        data.append(UInt8(nameBytes.count & 0xFF))
        data.append(nameBytes)
        data.append(contentsOf: [0x00, 0x01]) // value length = 1
        data.append(value ? 0x01 : 0x00)
    }

    // MARK: - HTTP

    private func sendHTTPResponse(fd: Int32, body: Data) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { write(fd, $0, strlen($0)) }
        body.withUnsafeBytes { write(fd, $0.baseAddress!, body.count) }
    }
}
