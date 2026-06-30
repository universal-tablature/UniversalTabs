import Foundation

public enum ValidationSeverity: String, Sendable {
    case warning
    case error
}

public struct ValidationDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public let severity: ValidationSeverity
    public let path: String
    public let message: String

    public init(severity: ValidationSeverity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(severity.rawValue): \(path): \(message)"
    }
}

public struct UTabValidator: Sendable {
    public init() {}

    public func validate(_ document: UTabDocument) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let profiles = index(
            document.setup.profiles,
            path: "setup.profiles",
            id: \.id,
            diagnostics: &diagnostics
        )
        let instruments = index(
            document.setup.instruments,
            path: "setup.instruments",
            id: \.id,
            diagnostics: &diagnostics
        )
        let performers = index(
            document.setup.performers ?? [],
            path: "setup.performers",
            id: \.id,
            diagnostics: &diagnostics
        )
        _ = index(
            document.tracks,
            path: "tracks",
            id: \.id,
            diagnostics: &diagnostics
        )

        for (profileIndex, profile) in document.setup.profiles.enumerated() {
            validateProfile(profile, path: "setup.profiles[\(profileIndex)]", diagnostics: &diagnostics)
        }

        for (instrumentIndex, instrument) in document.setup.instruments.enumerated() {
            if profiles[instrument.profile] == nil {
                diagnostics.append(.init(
                    severity: .error,
                    path: "setup.instruments[\(instrumentIndex)].profile",
                    message: "unresolved profile '\(instrument.profile)'"
                ))
            }
        }

        for (trackIndex, track) in document.tracks.enumerated() {
            let trackPath = "tracks[\(trackIndex)]"
            guard let instrument = instruments[track.instrument] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(trackPath).instrument",
                    message: "unresolved instrument '\(track.instrument)'"
                ))
                continue
            }
            if let performer = track.performer, performers[performer] == nil {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(trackPath).performer",
                    message: "unresolved performer '\(performer)'"
                ))
            }
            guard let profile = profiles[instrument.profile] else { continue }
            validateTrack(track, profile: profile, path: trackPath, diagnostics: &diagnostics)
        }
        return diagnostics
    }

    private func validateProfile(
        _ profile: InstrumentProfile,
        path: String,
        diagnostics: inout [ValidationDiagnostic]
    ) {
        guard let actuators = profile.actuators else {
            if profile.source == nil {
                diagnostics.append(.init(
                    severity: .error,
                    path: path,
                    message: "profile must define actuators or an external source"
                ))
            }
            return
        }

        var memberIDs = Set<String>()
        for (name, actuator) in actuators {
            let actuatorPath = "\(path).actuators.\(name)"
            if let count = actuator.count, count < 1 {
                diagnostics.append(.init(severity: .error, path: "\(actuatorPath).count", message: "must be positive"))
            }
            for (memberIndex, member) in (actuator.members ?? []).enumerated() {
                if !memberIDs.insert(member.id).inserted {
                    diagnostics.append(.init(
                        severity: .error,
                        path: "\(actuatorPath).members[\(memberIndex)].id",
                        message: "duplicate actuator member id '\(member.id)'"
                    ))
                }
            }
            if actuator.representation == "bitset" {
                guard let width = actuator.width, width > 0 else {
                    diagnostics.append(.init(
                        severity: .error,
                        path: "\(actuatorPath).width",
                        message: "bitset actuator requires a positive width"
                    ))
                    continue
                }
                var indices = Set<Int>()
                for (bitIndex, bit) in (actuator.bits ?? []).enumerated() {
                    let bitPath = "\(actuatorPath).bits[\(bitIndex)].index"
                    if bit.index < 0 || bit.index >= width {
                        diagnostics.append(.init(
                            severity: .error,
                            path: bitPath,
                            message: "bit index \(bit.index) is outside width \(width)"
                        ))
                    } else if !indices.insert(bit.index).inserted {
                        diagnostics.append(.init(
                            severity: .error,
                            path: bitPath,
                            message: "duplicate bit index \(bit.index)"
                        ))
                    }
                }
            }
        }
    }

    private func validateTrack(
        _ track: EventTrack,
        profile: InstrumentProfile,
        path: String,
        diagnostics: inout [ValidationDiagnostic]
    ) {
        guard profile.actuators != nil else {
            diagnostics.append(.init(
                severity: .warning,
                path: path,
                message: "events cannot be validated without loading external profile '\(profile.id)'"
            ))
            return
        }

        var stateAtTime: [String: [String: JSONValue]] = [:]
        for (eventIndex, event) in track.events.enumerated() {
            let eventPath = "\(path).events[\(eventIndex)]"
            if let action = event.action, !supports(action, in: profile.interactions) {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(eventPath).action",
                    message: "action '\(action)' is not defined by profile '\(profile.id)'"
                ))
            }
            if let gesture = event.gesture,
               !supports(gesture, in: profile.interactions),
               !supports(gesture, in: profile.techniques) {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(eventPath).gesture",
                    message: "gesture '\(gesture)' is not defined by profile '\(profile.id)'"
                ))
            }
            for (techniqueIndex, technique) in (event.techniques ?? []).enumerated()
                where !supports(technique, in: profile.techniques) {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(eventPath).techniques[\(techniqueIndex)]",
                    message: "technique '\(technique)' is not defined by profile '\(profile.id)'"
                ))
            }
            if let target = string(event.target) {
                validateTarget(target, profile: profile, path: "\(eventPath).target", diagnostics: &diagnostics)
            } else if event.target != nil {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(eventPath).target",
                    message: "structured targets are not yet semantically validated"
                ))
            }

            var localChanges: [String: JSONValue] = [:]
            for (changeIndex, change) in (event.changes ?? []).enumerated() {
                let changePath = "\(eventPath).changes[\(changeIndex)]"
                validateTarget(change.target, profile: profile, path: "\(changePath).target", diagnostics: &diagnostics)
                validateBitset(change, profile: profile, path: changePath, diagnostics: &diagnostics)

                let key = "\(change.target)\u{0}\(change.parameter)"
                if let existing = localChanges[key], existing != change.value {
                    diagnostics.append(.init(
                        severity: .error,
                        path: changePath,
                        message: "conflicting values for '\(change.target).\(change.parameter)' in one event"
                    ))
                }
                localChanges[key] = change.value

                let timedKey = "\(timeKey(event.at))\u{0}\(key)"
                if let existing = stateAtTime[timedKey]?["value"], existing != change.value {
                    diagnostics.append(.init(
                        severity: .error,
                        path: changePath,
                        message: "conflicting simultaneous state change for '\(change.target).\(change.parameter)'"
                    ))
                } else {
                    stateAtTime[timedKey] = ["value": change.value]
                }
            }
        }
    }

    private func validateTarget(
        _ target: String,
        profile: InstrumentProfile,
        path: String,
        diagnostics: inout [ValidationDiagnostic]
    ) {
        guard let actuators = profile.actuators else { return }
        if actuators[target] != nil { return }
        if actuators.values.contains(where: { ($0.members ?? []).contains(where: { $0.id == target }) }) { return }

        guard let address = parseAddress(target), let actuator = actuators[address.group] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "target '\(target)' does not resolve in profile '\(profile.id)'"
            ))
            return
        }
        guard let count = actuator.count else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "target '\(target)' indexes an actuator without a declared count"
            ))
            return
        }
        if address.first < 1 || address.last < address.first || address.last > count {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "target '\(target)' is outside actuator range 1...\(count)"
            ))
        }
    }

    private func validateBitset(
        _ change: StateChange,
        profile: InstrumentProfile,
        path: String,
        diagnostics: inout [ValidationDiagnostic]
    ) {
        guard change.parameter == "state",
              let actuator = profile.actuators?[change.target],
              actuator.representation == "bitset",
              let width = actuator.width else { return }
        guard let value = object(change.value),
              string(value["encoding"]) == "hex",
              let data = string(value["data"]),
              data.lowercased().hasPrefix("0x") else {
            diagnostics.append(.init(
                severity: .error,
                path: "\(path).value",
                message: "bitset state must use hexadecimal encoding"
            ))
            return
        }
        let digits = String(data.dropFirst(2))
        guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }) else {
            diagnostics.append(.init(
                severity: .error,
                path: "\(path).value.data",
                message: "invalid hexadecimal bitset"
            ))
            return
        }
        if bitLength(ofHex: digits) > width {
            diagnostics.append(.init(
                severity: .error,
                path: "\(path).value.data",
                message: "bitset value exceeds declared width \(width)"
            ))
        }
    }

    private func supports(_ name: String, in definitions: [String: JSONValue]?) -> Bool {
        definitions?[name] != nil
    }

    private func parseAddress(_ target: String) -> (group: String, first: Int, last: Int)? {
        guard let open = target.firstIndex(of: "["), target.last == "]" else { return nil }
        let group = String(target[..<open])
        let body = String(target[target.index(after: open)..<target.index(before: target.endIndex)])
        let parts = body.components(separatedBy: "..")
        if parts.count == 1, let value = Int(parts[0]) { return (group, value, value) }
        if parts.count == 2, let first = Int(parts[0]), let last = Int(parts[1]) { return (group, first, last) }
        return nil
    }

    private func bitLength(ofHex digits: String) -> Int {
        let trimmed = digits.drop(while: { $0 == "0" })
        guard let first = trimmed.first, let nibble = Int(String(first), radix: 16) else { return 0 }
        let leadingBits = nibble < 2 ? 1 : nibble < 4 ? 2 : nibble < 8 ? 3 : 4
        return (trimmed.count - 1) * 4 + leadingBits
    }

    private func timeKey(_ time: EventTime) -> String {
        if let musical = time.musical {
            return "m:\(musical.measure):\(valueKey(musical.beat))"
        }
        if let absolute = time.absolute { return "a:\(absolute.value):\(absolute.unit)" }
        return "invalid"
    }

    private func valueKey(_ value: JSONValue?) -> String {
        switch value {
        case .none: ""
        case .null?: "null"
        case .boolean(let value)?: "b:\(value)"
        case .number(let value)?: "n:\(value)"
        case .string(let value)?: "s:\(value)"
        case .array(let value)?: "a:\(value.map { valueKey($0) }.joined(separator: ","))"
        case .object(let value)?: "o:\(value.keys.sorted().map { "\($0)=\(valueKey(value[$0]))" }.joined(separator: ","))"
        }
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let value) = value else { return nil }
        return value
    }

    private func index<Element>(
        _ elements: [Element],
        path: String,
        id: KeyPath<Element, String>,
        diagnostics: inout [ValidationDiagnostic]
    ) -> [String: Element] {
        var result: [String: Element] = [:]
        for (offset, element) in elements.enumerated() {
            let identifier = element[keyPath: id]
            if result.updateValue(element, forKey: identifier) != nil {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(offset)].id",
                    message: "duplicate id '\(identifier)'"
                ))
            }
        }
        return result
    }
}
