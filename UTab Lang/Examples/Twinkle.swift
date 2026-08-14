// Example of Twinkle Twinkle Little Star using the experimental Swift frontend.
// This file is documentation; the executable integration version lives in
// Tests/UTABComposerTests/ComposerTests.swift.

import UTABComposerDSL

let melodyA = Phrase("melodyA") {
    Bar {
        C4(.quarter)
        C4(.quarter)
        G4(.quarter)
        G4(.quarter)
    }
    Bar {
        A4(.quarter)
        A4(.quarter)
        G4(.half)
    }
}

let wholeMeasureTonic = Chord(.c, .major, .whole)

let twinkle = Song(
    "Twinkle Twinkle Little Star",
    meter: TimeSignature(4, 4),
    tempo: 100,
    scale: Scale(.c, .major)
) {
    melodyA

    Section("verse", duration: MusicalDuration(2)) {
        Instrument("piano") {
            Voice("right hand", constraints: [.group("right hand")]) {
                Play("melodyA")
            }
            Voice("left hand", constraints: [.group("left hand")]) {
                wholeMeasureTonic
                wholeMeasureTonic
            }
        }
        Instrument("guitar") {
            Voice("chords") {
                wholeMeasureTonic
                wholeMeasureTonic
            }
        }
        Instrument("voice") {
            Voice("melody") {
                Play("melodyA")
            }
        }
    }
}

let diagnostics = CompositionValidator().validate(twinkle)
