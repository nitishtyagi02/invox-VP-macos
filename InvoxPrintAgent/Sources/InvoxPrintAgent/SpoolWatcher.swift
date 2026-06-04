import Foundation

protocol SpoolWatcherDelegate: AnyObject {
    func spoolWatcher(_ watcher: SpoolWatcher, didDetectNewPDF path: String, metadata: [String: String])
}

class SpoolWatcher {
    weak var delegate: SpoolWatcherDelegate?
    private var source: DispatchSourceFileSystemObject?
    private var knownFiles: Set<String> = []
    private let spoolPath: String

    init(path: String = Config.spoolDirectory) {
        self.spoolPath = path
    }

    func start() {
        // Ensure spool directory exists
        try? FileManager.default.createDirectory(atPath: spoolPath, withIntermediateDirectories: true)

        // Snapshot existing files
        knownFiles = Set(currentPDFs())

        // Monitor directory for changes
        let fd = open(spoolPath, O_EVTONLY)
        guard fd >= 0 else {
            print("[SpoolWatcher] Failed to open spool directory: \(spoolPath)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source?.setEventHandler { [weak self] in self?.checkForNewFiles() }
        source?.setCancelHandler { close(fd) }
        source?.resume()
        print("[SpoolWatcher] Monitoring: \(spoolPath)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func checkForNewFiles() {
        let pdfs = currentPDFs()
        let newFiles = Set(pdfs).subtracting(knownFiles)
        knownFiles = Set(pdfs)

        for file in newFiles {
            let meta = loadMetadata(for: file)
            delegate?.spoolWatcher(self, didDetectNewPDF: file, metadata: meta)
        }
    }

    private func currentPDFs() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: spoolPath) else { return [] }
        return files.filter { $0.hasSuffix(".pdf") }.map { "\(spoolPath)/\($0)" }
    }

    private func loadMetadata(for pdfPath: String) -> [String: String] {
        let metaPath = pdfPath.replacingOccurrences(of: ".pdf", with: ".meta")
        guard let content = try? String(contentsOfFile: metaPath, encoding: .utf8) else { return [:] }
        var meta: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { meta[String(parts[0])] = String(parts[1]) }
        }
        return meta
    }
}
