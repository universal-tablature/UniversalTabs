// Authoring a reusable instrument definition with the experimental Swift DSL.

import UTABComposerDSL
import UTABInstruments

let frettedStrings = Profile("profile:fretted-strings") {
    Actuators("strings", count: 4)
    Can("setPosition", target: "strings")
    Can("pluck", target: "strings", effectors: ["finger", "pick"])
    Technique("vibrato", target: "strings")
}

let sopranoUkulele = InstrumentModel(
    "instrument:ukulele:soprano",
    name: "Soprano Ukulele",
    profile: frettedStrings.id
) {
    Geometry("frets", [
        "count": .integer(15),
        "movable": .boolean(false),
    ])
    Default("tuning", .pitches([
        .init(.g, octave: 4),
        .init(.c, octave: 4),
        .init(.e, octave: 4),
        .init(.a, octave: 4),
    ]))
}

let library = InstrumentLibrary {
    frettedStrings
    sopranoUkulele
}

let myUkulele = ConfiguredInstrument(
    "my-ukulele",
    model: sopranoUkulele.id,
    configuration: ["leftHanded": .boolean(true)]
)

let diagnostics = InstrumentCatalogValidator().validate(library)

// Tunings preserve course order. A course can hold more than one string,
// including octave pairs used by instruments such as lutes.
let dadgad = Tuning("tuning:guitar:dadgad", name: "DADGAD") {
    Course(.init(.d, octave: 2))
    Course(.init(.a, octave: 2))
    Course(.init(.d, octave: 3))
    Course(.init(.g, octave: 3))
    Course(.init(.a, octave: 3))
    Course(.init(.d, octave: 4))
}
