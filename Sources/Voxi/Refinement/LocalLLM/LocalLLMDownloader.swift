import Foundation

/// Downloads a GGUF refiner model and verifies it (byte count + SHA-256)
/// before moving it into place — a failed check deletes the download and
/// throws, so a partial or tampered file can never be loaded.
actor LocalLLMDownloader {
    enum DownloadError: Error, LocalizedError {
        case badURL
        case badStatus(Int)
        case sizeMismatch(expected: Int64, got: Int64)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .badURL: "Model download URL is invalid"
            case .badStatus(let code): "Model download failed (HTTP \(code))"
            case .sizeMismatch(let expected, let got):
                "Model download incomplete (\(got) of \(expected) bytes)"
            case .checksumMismatch: "Model download failed integrity verification"
            }
        }
    }

    private var activeTask: Task<Void, Error>?

    /// Progress relay for the async download API. Holds only a @Sendable
    /// closure; @unchecked because NSObject can't declare Sendable.
    private final class ProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        // Required by the protocol; the async download API returns the file
        // location to the caller, so nothing to do here.
        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }

    func download(
        _ descriptor: GGUFModelDescriptor,
        to modelsDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: descriptor.url) else {
            throw DownloadError.badURL
        }
        let relay = ProgressRelay(onProgress: progress)
        let (tempFile, response) = try await URLSession.shared.download(from: url, delegate: relay)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: tempFile)
            throw DownloadError.badStatus(http.statusCode)
        }

        // Verify before install; never leave a bad file at the final path.
        let size = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        guard size == descriptor.expectedByteCount else {
            try? FileManager.default.removeItem(at: tempFile)
            throw DownloadError.sizeMismatch(expected: descriptor.expectedByteCount, got: size)
        }
        guard let digest = try? LocalLLMCatalog.sha256Hex(of: tempFile),
              digest == descriptor.expectedSHA256 else {
            try? FileManager.default.removeItem(at: tempFile)
            throw DownloadError.checksumMismatch
        }

        let destination = LocalLLMCatalog.fileURL(for: descriptor, under: modelsDir)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempFile, to: destination)
    }

    func delete(_ descriptor: GGUFModelDescriptor, from modelsDir: URL) {
        try? FileManager.default.removeItem(
            at: LocalLLMCatalog.fileURL(for: descriptor, under: modelsDir))
    }
}
