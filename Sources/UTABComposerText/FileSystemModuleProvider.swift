import Foundation

/// Resolves dotted module names from ordered search roots. Both conventional nested paths
/// (`instruments/guitar.utab`) and flat catalogue paths (`instruments.guitar.utab`) are supported.
public struct FileSystemTextModuleProvider: TextModuleProvider {
    public let searchRoots: [URL]

    public init(searchRoots: [URL]) {
        self.searchRoots = searchRoots
    }

    public func source(for moduleName: String) -> TextSource? {
        let nestedPath = moduleName.replacingOccurrences(of: ".", with: "/") + "." + UTabComposerLanguage.fileExtension
        let flatPath = moduleName + "." + UTabComposerLanguage.fileExtension
        for root in searchRoots {
            for relativePath in [nestedPath, flatPath] {
                let url = root.appendingPathComponent(relativePath)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                return .init(text, fileID: url.standardizedFileURL.path)
            }
        }
        return nil
    }
}

/// Queries providers in order, allowing project/package sources to shadow a standard library.
public struct LayeredTextModuleProvider: TextModuleProvider {
    public let providers: [any TextModuleProvider]

    public init(_ providers: [any TextModuleProvider]) {
        self.providers = providers
    }

    public func source(for moduleName: String) -> TextSource? {
        for provider in providers {
            if let source = provider.source(for: moduleName) { return source }
        }
        return nil
    }
}
