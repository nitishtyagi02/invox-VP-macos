import Foundation

class PrintJobReceiver {
    weak var delegate: SpoolWatcherDelegate?
    private var serverSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let port: UInt16 = 19283
    private let dummyWatcher = SpoolWatcher()

    func start() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { print("[Receiver] socket() failed"); return }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { print("[Receiver] bind() failed: \(errno)"); close(serverSocket); return }
        guard listen(serverSocket, 5) == 0 else { print("[Receiver] listen() failed"); close(serverSocket); return }

        listenSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global())
        listenSource?.setEventHandler { [weak self] in self?.acceptConnection() }
        listenSource?.setCancelHandler { [weak self] in if let s = self?.serverSocket, s >= 0 { close(s) } }
        listenSource?.resume()
        print("[Receiver] Listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverSocket, $0, &len) }
        }
        guard clientFd >= 0 else { return }
        DispatchQueue.global().async { self.handleRequest(fd: clientFd) }
    }

    private func handleRequest(fd: Int32) {
        defer { close(fd) }

        // Read headers (up to 8KB should be enough)
        var headerBuf = Data()
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { tmp.deallocate() }

        // Read byte by byte until we find \r\n\r\n
        while headerBuf.count < 8192 {
            let n = read(fd, tmp, 1)
            if n <= 0 { break }
            headerBuf.append(tmp, count: 1)
            if headerBuf.count >= 4 && headerBuf.suffix(4) == Data("\r\n\r\n".utf8) {
                break
            }
        }

        let headerStr = String(data: headerBuf, encoding: .utf8) ?? ""

        // Parse Content-Length
        var contentLength = 0
        var title = "Print Job"
        var jobId = "0"
        for line in headerStr.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("x-title:") {
                title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("x-job-id:") {
                jobId = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Read body
        var body = Data()
        if contentLength > 0 {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }
            while body.count < contentLength {
                let toRead = min(65536, contentLength - body.count)
                let n = read(fd, buf, toRead)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }

        // Save PDF to spool
        let spoolDir = Config.spoolDirectory
        try? FileManager.default.createDirectory(atPath: spoolDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let pdfPath = "\(spoolDir)/\(timestamp)_\(jobId).pdf"
        FileManager.default.createFile(atPath: pdfPath, contents: body)

        // Send HTTP response
        let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        _ = resp.withCString { write(fd, $0, strlen($0)) }

        // Notify delegate on main thread
        let pdfPathCopy = pdfPath
        let titleCopy = title
        let jobIdCopy = jobId
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.spoolWatcher(self.dummyWatcher, didDetectNewPDF: pdfPathCopy, metadata: ["title": titleCopy, "job_id": jobIdCopy])
        }
    }
}
