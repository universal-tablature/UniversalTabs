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

import Testing
import UTABComposerCore
@testable import UTABEditing

struct PitchSourceEditorTests {
    @Test("Absolute pitch edits preserve the expression")
    func editsAbsolutePitch() throws {
        let source = """
        phrase melody {
            C4 q
        }
        """
        let range = SourceRange(
            fileID: "main.utab",
            start: SourcePosition(line: 2, column: 5),
            end: SourcePosition(line: 2, column: 9)
        )

        let edit = try UTABPitchSourceEditor.setPitch(in: source, range: range, midiPitch: 66)

        #expect(edit.source == """
        phrase melody {
            F#4 q
        }
        """)
        #expect(edit.representationChange == .preserved)
        #expect(edit.replacement == "F#4")
        #expect(edit.replacementRange.start == SourcePosition(line: 2, column: 5))
        #expect(edit.replacementRange.end == SourcePosition(line: 2, column: 8))
    }

    @Test("Relative pitches normalize to an exact absolute pitch")
    func normalizesRelativePitch() throws {
        let source = """
        phrase melody {
            @1[4] q
        }
        """
        let range = SourceRange(
            fileID: "main.utab",
            start: SourcePosition(line: 2, column: 5),
            end: SourcePosition(line: 2, column: 12)
        )

        let edit = try UTABPitchSourceEditor.setPitch(in: source, range: range, midiPitch: 61)

        #expect(edit.source == """
        phrase melody {
            C#4 q
        }
        """)
        #expect(edit.representationChange == .normalizedToAbsolutePitch)
    }

    @Test("An unrelated source range is rejected without mutation")
    func rejectsNonPitchRange() {
        let source = "rest q"
        let range = SourceRange(
            fileID: "main.utab",
            start: SourcePosition(line: 1, column: 1),
            end: SourcePosition(line: 1, column: 7)
        )

        #expect(throws: UTABSourceEditingError.pitchNotFound(range)) {
            try UTABPitchSourceEditor.setPitch(in: source, range: range, midiPitch: 60)
        }
    }

    @Test("Overlapping notes normalize an explicit bar into parallel sequence lanes")
    func rewritesOverlappingBar() throws {
        let source = """
        phrase melody {
            bar {
                C4 q
                D4 q
                E4 q
                F4 q
            }
        }
        """
        let range = SourceRange(
            fileID: "main.utab",
            start: SourcePosition(line: 2, column: 5),
            end: SourcePosition(line: 7, column: 6)
        )

        let edit = try UTABMeasureSourceEditor.rewriteBar(
            in: source,
            range: range,
            notes: [
                .init(id: "c", midiPitch: 60, startBeat: 0, durationBeats: 2),
                .init(id: "d", midiPitch: 62, startBeat: 1, durationBeats: 1),
                .init(id: "e", midiPitch: 64, startBeat: 2, durationBeats: 1),
                .init(id: "f", midiPitch: 65, startBeat: 3, durationBeats: 1),
            ],
            beatsPerMeasure: 4
        )

        #expect(edit.source.contains("(C4 h; E4 q; F4 q), (_ q; D4 q; _ h)"))
    }

    @Test("Repeated implicit-measure rewrites preserve indentation")
    func implicitRewriteDoesNotAccumulateIndentation() throws {
        let source = """
        voice bass {
            E2 q
            A2 q
            D3 q
            E3 q
        }
        """
        let notes = [
            UTABTimedNoteEdit(id: "e", midiPitch: 40, startBeat: 0, durationBeats: 2),
            UTABTimedNoteEdit(id: "a", midiPitch: 45, startBeat: 1, durationBeats: 1),
            UTABTimedNoteEdit(id: "d", midiPitch: 50, startBeat: 2, durationBeats: 1),
            UTABTimedNoteEdit(id: "high-e", midiPitch: 52, startBeat: 3, durationBeats: 1),
        ]
        let first = try UTABMeasureSourceEditor.rewriteBar(
            in: source,
            range: SourceRange(
                fileID: "main.utab",
                start: SourcePosition(line: 2, column: 5),
                end: SourcePosition(line: 5, column: 9)
            ),
            notes: notes,
            beatsPerMeasure: 4,
            explicitBar: false
        )
        let finalParenthesis = try #require(first.replacement.lastIndex(of: ")"))
        let finalParenthesisOffset = first.replacement.distance(
            from: first.replacement.startIndex,
            to: finalParenthesis
        )
        let second = try UTABMeasureSourceEditor.rewriteBar(
            in: first.source,
            range: SourceRange(
                fileID: "main.utab",
                start: SourcePosition(line: 2, column: 6),
                end: SourcePosition(line: 2, column: 5 + finalParenthesisOffset)
            ),
            notes: notes,
            beatsPerMeasure: 4,
            explicitBar: false
        )

        #expect(first.source == second.source)
        #expect(first.source.contains("\n    (E2 h; D3 q; E3 q), (_ q; A2 q; _ h)\n"))
        #expect(!first.source.contains("\n        (E2 h"))
    }
}
