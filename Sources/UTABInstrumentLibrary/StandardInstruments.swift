import UTABComposerCore
import UTABComposerDSL
import UTABInstruments

public enum StandardInstruments {
    // MARK: Tunings

    public static let guitarStandard = Tuning("tuning:guitar:standard", name: "Guitar Standard", tags: ["guitar", "standard"]) {
        Course(.init(.e, octave: 2)); Course(.init(.a, octave: 2)); Course(.init(.d, octave: 3))
        Course(.init(.g, octave: 3)); Course(.init(.b, octave: 3)); Course(.init(.e, octave: 4))
    }

    public static let guitarDropD = Tuning("tuning:guitar:drop-d", name: "Guitar Drop D", tags: ["guitar", "alternate"]) {
        Course(.init(.d, octave: 2)); Course(.init(.a, octave: 2)); Course(.init(.d, octave: 3))
        Course(.init(.g, octave: 3)); Course(.init(.b, octave: 3)); Course(.init(.e, octave: 4))
    }

    public static let guitarDADGAD = Tuning("tuning:guitar:dadgad", name: "Guitar DADGAD", tags: ["guitar", "alternate", "open"]) {
        Course(.init(.d, octave: 2)); Course(.init(.a, octave: 2)); Course(.init(.d, octave: 3))
        Course(.init(.g, octave: 3)); Course(.init(.a, octave: 3)); Course(.init(.d, octave: 4))
    }

    public static let guitarleleStandard = Tuning("tuning:guitarlele:standard", name: "Guitarlele Standard (A–A)", tags: ["guitarlele", "standard"]) {
        Course(.init(.a, octave: 2)); Course(.init(.d, octave: 3)); Course(.init(.g, octave: 3))
        Course(.init(.c, octave: 4)); Course(.init(.e, octave: 4)); Course(.init(.a, octave: 4))
    }

    public static let banjoOpenG = Tuning("tuning:banjo-5:open-g", name: "Five-string Banjo Open G", tags: ["banjo", "reentrant", "open"]) {
        Course(.init(.g, octave: 4)); Course(.init(.d, octave: 3)); Course(.init(.g, octave: 3))
        Course(.init(.b, octave: 3)); Course(.init(.d, octave: 4))
    }

    public static let violinStandard = Tuning("tuning:violin:standard", name: "Violin Standard", tags: ["violin", "fifths"]) {
        Course(.init(.g, octave: 3)); Course(.init(.d, octave: 4))
        Course(.init(.a, octave: 4)); Course(.init(.e, octave: 5))
    }

    public static let celloStandard = Tuning("tuning:cello:standard", name: "Cello Standard", tags: ["cello", "fifths"]) {
        Course(.init(.c, octave: 2)); Course(.init(.g, octave: 2))
        Course(.init(.d, octave: 3)); Course(.init(.a, octave: 3))
    }

    public static let renaissanceLuteG = Tuning("tuning:lute:renaissance-g", name: "Six-course Renaissance Lute in G", tags: ["lute", "courses"]) {
        Course(.init(.g, octave: 2), .init(.g, octave: 3))
        Course(.init(.c, octave: 3), .init(.c, octave: 4))
        Course(.init(.f, octave: 3), .init(.f, octave: 4))
        Course(.init(.a, octave: 3), .init(.a, octave: 3))
        Course(.init(.d, octave: 4), .init(.d, octave: 4))
        Course(.init(.g, octave: 4), .init(.g, octave: 4))
    }

    public static let arabicOud = Tuning("tuning:oud:arabic-c", name: "Arabic Oud in C", tags: ["oud", "courses"]) {
        Course(.init(.c, octave: 2))
        Course(.init(.f, octave: 2), .init(.f, octave: 2))
        Course(.init(.a, octave: 2), .init(.a, octave: 2))
        Course(.init(.d, octave: 3), .init(.d, octave: 3))
        Course(.init(.g, octave: 3), .init(.g, octave: 3))
        Course(.init(.c, octave: 4), .init(.c, octave: 4))
    }

    // MARK: Capability profiles

    public static let frettedStrings = Profile("profile:fretted-strings") {
        Actuators("strings")
        Can("setPosition", target: "strings")
        Can("pluck", target: "strings", effectors: ["finger", "pick"])
        Can("strum", target: "strings", effectors: ["finger", "pick"])
        Technique("slide", target: "strings"); Technique("bend", target: "strings"); Technique("vibrato", target: "strings")
    }

    public static let pluckedCourses = Profile("profile:plucked-courses") {
        Actuators("courses")
        Can("setPosition", target: "courses")
        Can("pluck", target: "courses", effectors: ["finger", "plectrum"])
        Can("strum", target: "courses", effectors: ["finger", "plectrum"])
        Technique("tremolo", target: "courses")
    }

    public static let fretlessBowedStrings = Profile("profile:fretless-bowed-strings") {
        Actuators("strings", cardinality: .range(1...16), control: .continuous(range: 0...1))
        Can("setPosition", target: "strings")
        Can("bow", target: "strings", effectors: ["bow"])
        Can("pluck", target: "strings", effectors: ["finger"])
        Technique("vibrato", target: "strings"); Technique("pizzicato", target: "strings")
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

    // MARK: Concrete models

    public static let guitar = InstrumentModel("instrument:guitar:classical-six-string", name: "Six-string Classical Guitar", profile: frettedStrings.id) {
        Geometry("strings", ["count": .integer(6)]); Geometry("frets", ["count": .integer(19), "movable": .boolean(false)])
        Supports(guitarStandard, default: true); Supports(guitarDropD); Supports(guitarDADGAD)
    }

    public static let guitarlele = InstrumentModel("instrument:guitarlele:standard", name: "Six-string Guitarlele", profile: frettedStrings.id) {
        Geometry("strings", ["count": .integer(6)]); Geometry("frets", ["count": .integer(18), "movable": .boolean(false)])
        Supports(guitarleleStandard, default: true)
    }

    public static let fiveStringBanjo = InstrumentModel("instrument:banjo:five-string", name: "Five-string Banjo", profile: frettedStrings.id) {
        Geometry("strings", ["count": .integer(5), "reentrant": .boolean(true)]); Geometry("frets", ["count": .integer(22), "movable": .boolean(false)])
        Supports(banjoOpenG, default: true)
    }

    public static let violin = InstrumentModel("instrument:violin:four-string", name: "Four-string Violin", profile: fretlessBowedStrings.id) {
        Geometry("strings", ["count": .integer(4)]); Supports(violinStandard, default: true)
    }

    public static let cello = InstrumentModel("instrument:cello:four-string", name: "Four-string Cello", profile: fretlessBowedStrings.id) {
        Geometry("strings", ["count": .integer(4)]); Supports(celloStandard, default: true)
    }

    public static let renaissanceLute = InstrumentModel("instrument:lute:renaissance-six-course", name: "Six-course Renaissance Lute", profile: pluckedCourses.id) {
        Geometry("courses", ["count": .integer(6), "doubled": .boolean(true)]); Geometry("frets", ["movable": .boolean(true)])
        Supports(renaissanceLuteG, default: true)
    }

    public static let oud = InstrumentModel("instrument:oud:arabic-six-course", name: "Six-course Arabic Oud", profile: pluckedCourses.id) {
        Geometry("courses", ["count": .integer(6), "doubled": .boolean(true)]); Geometry("fingerboard", ["fretted": .boolean(false)])
        Supports(arabicOud, default: true)
    }

    public static let piano = InstrumentModel("instrument:piano:88-key", name: "88-key Piano", profile: keyboard.id) {
        Geometry("keyboard", ["lowestPitch": .pitch(.init(.a, octave: 0)), "highestPitch": .pitch(.init(.c, octave: 8))])
    }

    public static let voice = InstrumentModel("instrument:voice:generic", name: "Singing Voice", profile: singingVoice.id)

    public static let catalog = InstrumentLibrary {
        guitarStandard; guitarDropD; guitarDADGAD; guitarleleStandard; banjoOpenG
        violinStandard; celloStandard; renaissanceLuteG; arabicOud
        frettedStrings; pluckedCourses; fretlessBowedStrings; keyboard; singingVoice
        guitar; guitarlele; fiveStringBanjo; violin; cello; renaissanceLute; oud; piano; voice
    }
}
