import Foundation

/// Canonical filesystem locations. Everything Voxi persists lives under
/// ~/Library/Application Support/Voxi/.
enum VoxiPaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Root for downloaded ASR models: Models/<engineID>/…
    static func modelsDir(engineID: String) -> URL {
        let dir = appSupport.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(engineID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL {
        appSupport.appendingPathComponent("voxi.sqlite")
    }
}
