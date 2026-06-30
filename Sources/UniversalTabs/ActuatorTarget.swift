import Foundation

public struct ActuatorTarget: Sendable, Equatable {
    public enum Selector: Sendable, Equatable {
        case index(Int)
        case range(ClosedRange<Int>)
        case member(String)
    }

    public let path: [String]
    public let selector: Selector?

    public var groupPath: String { path.joined(separator: ".") }

    public init(parsing source: String) throws {
        guard !source.isEmpty, !source.contains(where: \Character.isWhitespace) else {
            throw ActuatorTargetError.invalidSyntax(source)
        }

        let pathText: Substring
        let selectorText: Substring?
        if let opening = source.firstIndex(of: "[") {
            guard source.last == "]", source[source.index(after: opening)..<source.index(before: source.endIndex)].first != nil else {
                throw ActuatorTargetError.invalidSyntax(source)
            }
            pathText = source[..<opening]
            selectorText = source[source.index(after: opening)..<source.index(before: source.endIndex)]
        } else {
            pathText = source[...]
            selectorText = nil
        }

        let segments = pathText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy(Self.isIdentifier) else {
            throw ActuatorTargetError.invalidPath(String(pathText))
        }
        path = segments

        guard let selectorText else {
            selector = nil
            return
        }
        if selectorText.first == "\"" {
            guard selectorText.last == "\"",
                  let data = String(selectorText).data(using: .utf8),
                  let member = try? JSONDecoder().decode(String.self, from: data),
                  !member.isEmpty else {
                throw ActuatorTargetError.invalidSelector(String(selectorText))
            }
            selector = .member(member)
            return
        }
        let bounds = selectorText.split(separator: ".", omittingEmptySubsequences: false)
        if bounds.count == 1, let index = Int(bounds[0]), index > 0 {
            selector = .index(index)
            return
        }
        if bounds.count == 3, bounds[1].isEmpty,
           let first = Int(bounds[0]), let last = Int(bounds[2]),
           first > 0, last >= first {
            selector = .range(first...last)
            return
        }
        throw ActuatorTargetError.invalidSelector(String(selectorText))
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              isASCIIAlpha(first) || first == 95 else { return false }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlpha($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIIAlpha(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }
}

public enum ActuatorTargetError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSyntax(String)
    case invalidPath(String)
    case invalidSelector(String)

    public var description: String {
        switch self {
        case .invalidSyntax(let value): "invalid actuator target syntax: '\(value)'"
        case .invalidPath(let value): "invalid actuator target path: '\(value)'"
        case .invalidSelector(let value): "invalid actuator target selector: '[\(value)]'"
        }
    }
}
