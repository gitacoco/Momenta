import AppKit
import Foundation

/// Local storage for client logos, one image per client, in App Support.
enum LogoStore {
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Momenta/Logos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for fileName: String) -> URL {
        directory.appending(path: fileName)
    }

    /// Copies the picked image into the store; returns the stored file name.
    static func importLogo(from source: URL, for clientID: Int) throws -> String {
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let fileName = "client-\(clientID).\(ext)"
        let destination = url(for: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        removeSupersededLogos(for: clientID, keeping: fileName)
        return fileName
    }

    static func deleteLogo(named fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Atomically installs bytes fetched from a CloudKit asset. The file name
    /// is device-local and never appears in the synced config payload.
    static func installSyncedLogo(_ data: Data, for clientID: Int) throws -> String {
        let fileName = "client-\(clientID)-icloud"
        try data.write(to: url(for: fileName), options: .atomic)
        removeSupersededLogos(for: clientID, keeping: fileName)
        return fileName
    }

    private static func removeSupersededLogos(for clientID: Int, keeping keptFileName: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let localPrefix = "client-\(clientID)."
        let syncedName = "client-\(clientID)-icloud"
        for file in files {
            let name = file.lastPathComponent
            guard name != keptFileName,
                  name == syncedName || name.hasPrefix(localPrefix)
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func image(named fileName: String?) -> NSImage? {
        guard let fileName else { return nil }
        return NSImage(contentsOf: url(for: fileName))
    }
}
