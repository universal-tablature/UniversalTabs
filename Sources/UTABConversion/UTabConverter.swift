import Foundation
import UTABComposerCore
import UTABComposerText
import UTABInstrumentLibrary
import UTABLowering
import UniversalTabs

public enum UTabConversionFormat: String, CaseIterable, Sendable {
    case uTab = "utab"
    case uTabJSON = "utab-json"
    case mei
    case lilyPond = "lilypond"
    case musicXML = "musicxml"
    case mnx

    public var fileExtension: String {
        switch self {
        case .uTab: "utab"
        case .uTabJSON: "utab.json"
        case .mei: "mei"
        case .lilyPond: "ly"
        case .musicXML: "musicxml"
        case .mnx: "mnx"
        }
    }

    public var canImport: Bool { self != .lilyPond }
}

public struct UTabConversionResult: Sendable {
    public let data: Data
    public let inputFormat: UTabConversionFormat
    public let outputFormat: UTabConversionFormat
    public let diagnostics: [String]
}

public enum UTabGeneralConversionError: Error, CustomStringConvertible {
    case unknownInputFormat
    case unsupportedImport(UTabConversionFormat)
    case compilationFailed([String])

    public var description: String {
        switch self {
        case .unknownInputFormat: "could not detect input format; pass --from explicitly"
        case .unsupportedImport(let format): "\(format.rawValue) is export-only and cannot be used as an input format"
        case .compilationFailed(let messages): "UTAB composer compilation failed:\n" + messages.joined(separator: "\n")
        }
    }
}

public struct UTabConverter: Sendable {
    public init() {}

    public func detectFormat(data: Data, fileName: String? = nil) throws -> UTabConversionFormat {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if object["mnx"] != nil && object["global"] != nil && object["parts"] != nil { return .mnx }
                if object["utab"] != nil && object["setup"] != nil && object["tracks"] != nil { return .uTabJSON }
            }
        }
        if prefix.hasPrefix("<") || prefix.hasPrefix("<?xml") {
            if prefix.range(of: #"<(?:[A-Za-z0-9_-]+:)?mei(?:\s|>)"#, options: .regularExpression) != nil { return .mei }
            if prefix.contains("<score-partwise") || prefix.contains("<score-timewise") { return .musicXML }
        }
        if prefix.contains("\\version") && (prefix.contains("\\score") || prefix.contains("\\relative")) { return .lilyPond }
        if looksLikeComposerSource(prefix) { return .uTab }

        if let name = fileName?.lowercased() {
            if name.hasSuffix(".utab.json") { return .uTabJSON }
            if name.hasSuffix(".utab") { return .uTab }
            if name.hasSuffix(".musicxml") || name.hasSuffix(".xml") { return .musicXML }
            if name.hasSuffix(".mei") { return .mei }
            if name.hasSuffix(".mnx") { return .mnx }
            if name.hasSuffix(".ly") || name.hasSuffix(".ily") { return .lilyPond }
            if name.hasSuffix(".json") {
                throw UTabGeneralConversionError.unknownInputFormat
            }
        }
        throw UTabGeneralConversionError.unknownInputFormat
    }

    public func convert(
        _ data: Data,
        from explicitInput: UTabConversionFormat? = nil,
        to output: UTabConversionFormat,
        fileName: String? = nil
    ) throws -> UTabConversionResult {
        let input = try explicitInput ?? detectFormat(data: data, fileName: fileName)
        guard input.canImport else { throw UTabGeneralConversionError.unsupportedImport(input) }
        var diagnostics: [String] = []
        let json: Data
        switch input {
        case .uTab:
            let source = TextSource(String(decoding: data, as: UTF8.self), fileID: fileName ?? "converted.utab")
            let result = UTabTextCompiler().compile(
                source,
                modules: StandardTextModuleProvider(),
                options: .init(outputs: [.uTabJSON], prettyPrintedJSON: true)
            )
            let messages = result.diagnostics.map(\.description)
            guard result.succeeded, let artifact = result.artifact(.uTabJSON) else {
                throw UTabGeneralConversionError.compilationFailed(messages)
            }
            diagnostics += messages
            json = artifact.data
        case .uTabJSON:
            _ = try JSONDecoder().decode(UTabDocument.self, from: data)
            json = data
        case .mei:
            let result = try MEIInterchange.importDocument(data); json = result.data; diagnostics += result.diagnostics
        case .musicXML:
            let result = try MusicXMLInterchange.importDocument(data); json = result.data; diagnostics += result.diagnostics
        case .mnx:
            let result = try MNXDraft1Interchange.importDocument(data); json = result.data; diagnostics += result.diagnostics
        case .lilyPond:
            throw UTabGeneralConversionError.unsupportedImport(input)
        }

        let converted: Data
        switch output {
        case .uTabJSON:
            converted = normalizedJSON(json)
        case .uTab:
            let result = try UTabComposerDecompiler.decompile(json)
            converted = Data(result.source.utf8); diagnostics += result.diagnostics
        case .mei:
            let result = try MEIInterchange.exportDocument(json); converted = result.data; diagnostics += result.diagnostics
        case .lilyPond:
            let result = try LilyPondInterchange.exportDocument(json); converted = result.data; diagnostics += result.diagnostics
        case .musicXML:
            let result = try MusicXMLInterchange.exportDocument(json); converted = result.data; diagnostics += result.diagnostics
        case .mnx:
            let result = try MNXDraft1Interchange.exportDocument(json); converted = result.data; diagnostics += result.diagnostics
        }
        return .init(data: converted, inputFormat: input, outputFormat: output, diagnostics: diagnostics)
    }

    private func normalizedJSON(_ data: Data) -> Data {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let normalized = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return data }
        return normalized
    }

    private func looksLikeComposerSource(_ source: String) -> Bool {
        let declarations = ["module ", "import ", "title ", "meter ", "profile ", "model ", "instrument ", "phrase ", "section ", "main "]
        return declarations.contains { source.hasPrefix($0) || source.contains("\n\($0)") }
    }
}
