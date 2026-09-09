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

public enum Pitch {
    public static func midiNote(_ name: String) -> Int? {
        let characters = Array(name)
        guard characters.count >= 2 else { return nil }
        let offsets: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let letter = characters.first,
              let normalizedLetter = letter.uppercased().first,
              var semitone = offsets[normalizedLetter] else { return nil }

        var octaveStart = 1
        if characters[1] == "#" {
            semitone += 1
            octaveStart += 1
        } else if characters[1] == "b" {
            semitone -= 1
            octaveStart += 1
        }

        guard octaveStart < characters.count,
              let octave = Int(String(characters[octaveStart...])) else { return nil }
        let result = (octave + 1) * 12 + semitone
        return (0...127).contains(result) ? result : nil
    }
}
