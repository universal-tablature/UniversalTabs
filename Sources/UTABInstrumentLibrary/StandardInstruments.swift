import UTABComposerText
import UTABInstruments
import UTABLowering

/// Compatibility accessors for the catalogue authored in `Stdlib/*.utab`.
public enum StandardInstruments {
    public static let catalog: InstrumentCatalog = {
        let root = TextSource(
            "module standard.library\nimport instruments.standard\n",
            fileID: "<standard-library>"
        )
        let loaded = TextModuleLoader().load(root: root, provider: StandardTextModuleProvider())
        let compiled = TextInstrumentCatalogCompiler().compile(
            loaded.modules,
            extending: .init(profiles: [], models: [])
        )
        let diagnostics = loaded.diagnostics.map(\.description) + compiled.diagnostics.map(\.description)
        precondition(
            loaded.succeeded && compiled.succeeded,
            "The bundled UTAB instrument standard library is invalid:\n\(diagnostics.joined(separator: "\n"))"
        )
        return compiled.catalog
    }()

    public static let guitarStandard = tuning("tuning:guitar:standard")
    public static let guitarDropD = tuning("tuning:guitar:drop-d")
    public static let guitarDADGAD = tuning("tuning:guitar:dadgad")
    public static let twelveStringGuitarStandard = tuning("tuning:guitar-12:standard")
    public static let guitarleleStandard = tuning("tuning:guitarlele:standard")
    public static let electricGuitarStandard = tuning("tuning:electric-guitar:standard")
    public static let sopranoUkuleleHighG = tuning("tuning:ukulele:soprano-high-g")
    public static let mandolinStandard = tuning("tuning:mandolin:standard")
    public static let banjoOpenG = tuning("tuning:banjo-5:open-g")
    public static let violinStandard = tuning("tuning:violin:standard")
    public static let violaStandard = tuning("tuning:viola:standard")
    public static let celloStandard = tuning("tuning:cello:standard")
    public static let doubleBassOrchestral = tuning("tuning:double-bass:orchestral")
    public static let electricBassStandard = tuning("tuning:electric-bass:standard")
    public static let fretlessElectricBassStandard = tuning("tuning:electric-bass:fretless-standard")
    public static let renaissanceLuteG = tuning("tuning:lute:renaissance-g")
    public static let arabicOud = tuning("tuning:oud:arabic-c")

    public static let frettedStrings = profile("profile:fretted-strings")
    public static let pluckedCourses = profile("profile:plucked-courses")
    public static let fretlessBowedStrings = profile("profile:fretless-bowed-strings")
    public static let fretlessPluckedStrings = profile("profile:fretless-plucked-strings")
    public static let fourValveBrass = profile("profile:wind:four-valve-brass")
    public static let doubleValveSlideBrass = profile("profile:wind:double-valve-slide-brass")
    public static let harpsichordKeyboard = profile("profile:keyboard:harpsichord")
    public static let pipeOrganConsole = profile("profile:keyboard:pipe-organ-console")
    public static let patchSynthesizer = profile("profile:keyboard:patch-synthesizer")
    public static let keyboard = profile("profile:keyboard")
    public static let singingVoice = profile("profile:singing-voice")

    public static let guitar = model("instrument:guitar:classical-six-string")
    public static let twelveStringGuitar = model("instrument:guitar:twelve-string")
    public static let guitarlele = model("instrument:guitarlele:standard")
    public static let electricGuitar = model("instrument:guitar:electric-six-string")
    public static let sopranoUkulele = model("instrument:ukulele:soprano")
    public static let mandolin = model("instrument:mandolin:eight-string")
    public static let fiveStringBanjo = model("instrument:banjo:five-string")
    public static let violin = model("instrument:violin:four-string")
    public static let viola = model("instrument:viola:four-string")
    public static let cello = model("instrument:cello:four-string")
    public static let doubleBass = model("instrument:double-bass:four-string")
    public static let electricBass = model("instrument:electric-bass:four-string-fretted")
    public static let fretlessElectricBass = model("instrument:electric-bass:four-string-fretless")
    public static let doubleHorn = model("instrument:horn:double-f-b-flat")
    public static let euphonium = model("instrument:euphonium:b-flat-four-valve")
    public static let tuba = model("instrument:tuba:cc-four-valve")
    public static let bassTrombone = model("instrument:trombone:bass-b-flat")
    public static let doubleManualHarpsichord = model("instrument:harpsichord:double-manual-five-octave")
    public static let threeManualPipeOrgan = model("instrument:pipe-organ:three-manual")
    public static let performanceSynthesizer = model("instrument:synthesizer:performance-61-key")
    public static let renaissanceLute = model("instrument:lute:renaissance-six-course")
    public static let oud = model("instrument:oud:arabic-six-course")
    public static let piano = model("instrument:piano:88-key")
    public static let voice = model("instrument:voice:generic")

    private static func tuning(_ id: String) -> InstrumentTuningDefinition {
        guard let value = catalog.tunings.first(where: { $0.id.rawValue == id }) else {
            preconditionFailure("Missing standard tuning '\(id)'")
        }
        return value
    }

    private static func profile(_ id: String) -> InstrumentProfileDefinition {
        guard let value = catalog.profiles.first(where: { $0.id.rawValue == id }) else {
            preconditionFailure("Missing standard profile '\(id)'")
        }
        return value
    }

    private static func model(_ id: String) -> InstrumentModelDefinition {
        guard let value = catalog.models.first(where: { $0.id.rawValue == id }) else {
            preconditionFailure("Missing standard instrument model '\(id)'")
        }
        return value
    }
}
