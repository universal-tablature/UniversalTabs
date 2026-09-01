import Foundation
import ZIPFoundation

public enum ZIPArchiveExtractor {
    public static func extract(_ archiveURL: URL, to destinationURL: URL) throws {
        try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)
    }

    public static func extractBundledEmilyGuitar(to destinationURL: URL) throws {
        guard let archiveURL = Bundle.module.url(
            forResource: "Karoryfer.Emilyguitar.v1.001",
            withExtension: "zip",
            subdirectory: "SFZ"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try extract(archiveURL, to: destinationURL)
    }
}
