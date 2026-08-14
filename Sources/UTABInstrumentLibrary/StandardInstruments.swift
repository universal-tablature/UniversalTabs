import UTABComposerCore
import UTABComposerDSL
import UTABInstruments

public enum StandardInstruments {
    public static let frettedStrings = Profile("profile:fretted-strings") {
        Actuators("strings", count: 6)
        Can("setPosition", target: "strings")
        Can("pluck", target: "strings", effectors: ["finger", "pick"])
        Can("strum", target: "strings", effectors: ["finger", "pick"])
        Technique("slide", target: "strings")
        Technique("bend", target: "strings")
        Technique("vibrato", target: "strings")
    }

    public static let keyboard = Profile("profile:keyboard") {
        Actuators("keys", count: 88)
        Actuators("pedals", count: 3, control: .continuous(range: 0...1))
        Can("press", target: "keys", effectors: ["finger"])
        Can("press", target: "pedals", effectors: ["foot"])
    }

    public static let singingVoice = Profile("profile:singing-voice") {
        Actuators("voice", count: 1, control: .continuous(range: nil))
        Can("sing", target: "voice", effectors: ["breath"])
        Technique("vibrato", target: "voice")
    }

    public static let guitar = InstrumentModel(
        "instrument:guitar:classical-six-string",
        name: "Six-string Classical Guitar",
        profile: frettedStrings.id
    ) {
        Geometry("frets", ["count": .integer(19), "movable": .boolean(false)])
        Default("tuning", .pitches([
            .init(.e, octave: 2), .init(.a, octave: 2), .init(.d, octave: 3),
            .init(.g, octave: 3), .init(.b, octave: 3), .init(.e, octave: 4),
        ]))
    }

    public static let piano = InstrumentModel(
        "instrument:piano:88-key",
        name: "88-key Piano",
        profile: keyboard.id
    ) {
        Geometry("keyboard", ["lowestPitch": .pitch(.init(.a, octave: 0)), "highestPitch": .pitch(.init(.c, octave: 8))])
    }

    public static let voice = InstrumentModel(
        "instrument:voice:generic",
        name: "Singing Voice",
        profile: singingVoice.id
    )

    public static let catalog = InstrumentLibrary {
        frettedStrings
        keyboard
        singingVoice
        guitar
        piano
        voice
    }
}
