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
        return fileName
    }

    static func deleteLogo(named fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func image(named fileName: String?) -> NSImage? {
        guard let fileName else { return nil }
        return NSImage(contentsOf: url(for: fileName))
    }
}
