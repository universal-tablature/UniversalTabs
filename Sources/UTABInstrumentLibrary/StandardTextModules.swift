// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
