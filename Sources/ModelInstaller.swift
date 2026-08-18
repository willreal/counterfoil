import Foundation

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let queue: OperationQueue
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3600
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let stableURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("counterfoil-model-download-\(UUID().uuidString).tar.gz")
            try FileManager.default.moveItem(at: location, to: stableURL)
            guard let response = downloadTask.response else {
                throw NSError(domain: "download", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download returned no response"])
            }
            finish(.success((stableURL, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

enum ModelInstaller {
    static func install(
        urlString: String,
        modelName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        let downloader = ModelDownloadDelegate(progress: progress)
        let (archiveURL, response) = try await downloader.download(from: url)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "download", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP error"])
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("counterfoil-model-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        try await extract(archiveURL: archiveURL, destination: stagingRoot)
        guard let candidate = findModelDirectory(in: stagingRoot),
              Transcriber.modelDirectoryIsComplete(candidate) else {
            throw NSError(domain: "download", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded model is incomplete"])
        }
        try installAtomically(candidate: candidate, modelName: modelName)
        progress(1)
    }

    private static func extract(archiveURL: URL, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archiveURL.path, "-C", destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "download", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive"])
            }
        }.value
    }

    private static func findModelDirectory(in root: URL) -> URL? {
        if Transcriber.modelDirectoryIsComplete(root) { return root }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if Transcriber.modelDirectoryIsComplete(url) { return url }
        }
        return nil
    }

    private static func installAtomically(candidate: URL, modelName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Transcriber.modelsDir, withIntermediateDirectories: true)
        let destination = Transcriber.installDirectory(for: modelName)
        let replacement = Transcriber.modelsDir
            .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let backup = Transcriber.modelsDir
            .appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)

        try fm.copyItem(at: candidate, to: replacement)
        guard Transcriber.modelDirectoryIsComplete(replacement) else {
            try? fm.removeItem(at: replacement)
            throw NSError(domain: "download", code: 5, userInfo: [NSLocalizedDescriptionKey: "Staged model validation failed"])
        }

        var backedUp = false
        if fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: destination, to: backup)
            backedUp = true
        }
        do {
            try fm.moveItem(at: replacement, to: destination)
            if backedUp { try? fm.removeItem(at: backup) }
        } catch {
            try? fm.removeItem(at: replacement)
            if backedUp, fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }
}
