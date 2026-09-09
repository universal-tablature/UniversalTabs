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

public struct MIDIMessage: Sendable {
    public let tick: Int
    public let priority: Int
    public let bytes: [UInt8]

    public init(tick: Int, priority: Int = 1, bytes: [UInt8]) {
        self.tick = tick
        self.priority = priority
        self.bytes = bytes
    }
}

public enum StandardMIDIFile {
    public static let ticksPerQuarter = 480

    public static func make(conductor: [MIDIMessage], tracks: [[MIDIMessage]]) -> Data {
        var output = Data("MThd".utf8)
        output.appendUInt32(6)
        output.appendUInt16(1)
        output.appendUInt16(UInt16(tracks.count + 1))
        output.appendUInt16(UInt16(ticksPerQuarter))
        output.append(trackChunk(conductor))
        for track in tracks {
            output.append(trackChunk(track))
        }
        return output
    }

    public static func conductorTrack(bpm: Double, numerator: Int, denominator: Int) -> [MIDIMessage] {
        return [
            tempoChange(bpm: bpm, tick: 0),
            meterChange(numerator: numerator, denominator: denominator, tick: 0)
        ]
    }

    public static func tempoChange(bpm: Double, tick: Int) -> MIDIMessage {
        let microseconds = Int((60_000_000 / max(1, bpm)).rounded())
        return MIDIMessage(tick: tick, priority: 0, bytes: [
            0xFF, 0x51, 0x03,
            UInt8((microseconds >> 16) & 0xFF),
            UInt8((microseconds >> 8) & 0xFF),
            UInt8(microseconds & 0xFF)
        ])
    }

    public static func meterChange(numerator: Int, denominator: Int, tick: Int) -> MIDIMessage {
        let denominatorPower = UInt8(max(0, Int(log2(Double(max(1, denominator))))))
        return MIDIMessage(tick: tick, priority: 0, bytes: [
            0xFF, 0x58, 0x04, UInt8(clamping: numerator), denominatorPower, 24, 8
        ])
    }

    public static func trackName(_ name: String) -> MIDIMessage {
        let bytes = Array(name.utf8.prefix(127))
        return MIDIMessage(tick: 0, priority: 0, bytes: [0xFF, 0x03] + variableLength(bytes.count) + bytes)
    }

    private static func trackChunk(_ messages: [MIDIMessage]) -> Data {
        let sorted = messages.enumerated().sorted {
            if $0.element.tick != $1.element.tick { return $0.element.tick < $1.element.tick }
            if $0.element.priority != $1.element.priority { return $0.element.priority < $1.element.priority }
            return $0.offset < $1.offset
        }

        var body = Data()
        var previousTick = 0
        for (_, message) in sorted {
            let tick = max(previousTick, message.tick)
            body.append(contentsOf: variableLength(tick - previousTick))
            body.append(contentsOf: message.bytes)
            previousTick = tick
        }
        body.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])

        var chunk = Data("MTrk".utf8)
        chunk.appendUInt32(UInt32(body.count))
        chunk.append(body)
        return chunk
    }

    private static func variableLength(_ value: Int) -> [UInt8] {
        var value = max(0, value)
        var buffer = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            buffer.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        return buffer.reversed()
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ])
    }
}
