import Foundation
import UTABComposerText

/// Language modules shipped with Universal Tabs. Applications may layer their own provider
/// in front of this one when resolving project-local or package modules.
public struct StandardTextModuleProvider: TextModuleProvider {
    public init() {}

    public func source(for moduleName: String) -> TextSource? {
        guard let url = Bundle.module.url(
            forResource: moduleName,
            withExtension: UTabComposerLanguage.fileExtension,
            subdirectory: "Stdlib"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return .init(text, fileID: url.path)
    }
}
