import Testing
import UTABComposerCore
import UTABComposerDSL
import UTABInstrumentLibrary
import UTABInstruments

@Test func sequentialAndParallelDurationsFollowCompositionAlgebra() {
    let sequence = MusicalExpression.sequence([
        .rest(.quarter),
        .rest(.half),
    ])
    let parallel = MusicalExpression.parallel([
        .rest(.quarter),
        .rest(.whole),
    ])

    #expect(sequence.duration == MusicalDuration(3, 4))
    #expect(parallel.duration == .whole)
}

@Test func resolvesScaleRelativePitch() {
    let cMajor = Scale(.c, .major)
    #expect(cMajor.resolve(degree: 1, octave: 4) == AbsolutePitch(.c, octave: 4))
    #expect(cMajor.resolve(degree: 5, octave: 4) == AbsolutePitch(.g, octave: 4))
    #expect(cMajor.resolve(degree: 8, octave: 4) == AbsolutePitch(.c, octave: 5))
}

@Test func validatorReportsWrongBarAndIndependentVoiceDurations() {
    let composition = Song("Broken", meter: .init(4, 4), tempo: 100) {
        Phrase("short") {
            Bar { C4(.quarter) }
        }
        Section("verse", duration: .whole) {
            Instrument("piano") {
                Voice("right hand") { Play("short") }
            }
        }
    }

    let diagnostics = CompositionValidator().validate(composition)
    #expect(diagnostics.count == 2)
    #expect(diagnostics.contains { $0.path.contains("bars") })
    #expect(diagnostics.contains { $0.path.contains("voices") })
}

@Test func buildsAValidatedTwinkleArrangement() {
    let melodyA = Phrase("melodyA") {
        Bar {
            C4(.quarter); C4(.quarter); G4(.quarter); G4(.quarter)
        }
        Bar {
            A4(.quarter); A4(.quarter); G4(.half)
        }
    }
    let heldTonic = MusicalExpression.chord(.init(.c, .major), duration: .whole)

    let twinkle = Song(
        "Twinkle Twinkle Little Star",
        meter: .init(4, 4),
        tempo: 100,
        scale: .init(.c, .major)
    ) {
        melodyA
        Section("verse", duration: MusicalDuration(2)) {
            Instrument("piano") {
                Voice("right hand", constraints: [.group("right hand")]) { Play("melodyA") }
                Voice("left hand", constraints: [.group("left hand")]) {
                    heldTonic
                    heldTonic
                }
            }
            Instrument("guitar") {
                Voice("chords") {
                    heldTonic
                    heldTonic
                }
            }
            Instrument("voice") {
                Voice("melody") { Play("melodyA") }
            }
        }
    }

    #expect(twinkle.phrases.first?.duration == MusicalDuration(2))
    #expect(CompositionValidator().validate(twinkle).isEmpty)
}

@Test func buildsAndValidatesAHighLevelInstrumentLibrary() {
    let frettedStrings = Profile("profile:test-fretted") {
        Actuators("strings", count: 4)
        Can("pluck", target: "strings", effectors: ["finger"])
        Technique("vibrato", target: "strings")
    }
    let ukulele = InstrumentModel(
        "instrument:ukulele:soprano",
        name: "Soprano Ukulele",
        profile: frettedStrings.id
    ) {
        Geometry("frets", ["count": .integer(15), "movable": .boolean(false)])
        Default("tuning", .pitches([
            .init(.g, octave: 4), .init(.c, octave: 4),
            .init(.e, octave: 4), .init(.a, octave: 4),
        ]))
    }
    let catalog = InstrumentLibrary {
        frettedStrings
        ukulele
    }
    let instance = ConfiguredInstrument(
        "my-ukulele",
        model: ukulele.id,
        configuration: ["leftHanded": .boolean(true)]
    )

    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
    #expect(InstrumentCatalogValidator().validate(instance, in: catalog).isEmpty)
    #expect(ukulele.geometry.first?.properties["count"] == .integer(15))
}

@Test func standardInstrumentLibraryIsInternallyValid() {
    let catalog = StandardInstruments.catalog
    #expect(catalog.tunings.count == 10)
    #expect(catalog.profiles.count == 5)
    #expect(catalog.models.count == 10)
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func twelveStringGuitarHasSixDoubledCoursesWithStandardOctaves() {
    let tuning = StandardInstruments.twelveStringGuitarStandard
    let guitar = StandardInstruments.twelveStringGuitar

    #expect(tuning.courses.count == 6)
    #expect(tuning.courses.allSatisfy { $0.pitches.count == 2 })
    #expect(tuning.courses[0].pitches == [AbsolutePitch(.e, octave: 2), AbsolutePitch(.e, octave: 3)])
    #expect(tuning.courses[1].pitches == [AbsolutePitch(.a, octave: 2), AbsolutePitch(.a, octave: 3)])
    #expect(tuning.courses[2].pitches == [AbsolutePitch(.d, octave: 3), AbsolutePitch(.d, octave: 4)])
    #expect(tuning.courses[3].pitches == [AbsolutePitch(.g, octave: 3), AbsolutePitch(.g, octave: 4)])
    #expect(tuning.courses[4].pitches == [AbsolutePitch(.b, octave: 3), AbsolutePitch(.b, octave: 3)])
    #expect(tuning.courses[5].pitches == [AbsolutePitch(.e, octave: 4), AbsolutePitch(.e, octave: 4)])
    #expect(guitar.defaultTuning == tuning.id)
    #expect(guitar.geometry.first { $0.id == "courses" }?.properties["count"] == .integer(6))
    #expect(guitar.geometry.first { $0.id == "strings" }?.properties["count"] == .integer(12))
}

@Test func standardTuningsRepresentAlternateReentrantAndDoubledCourses() {
    let dropD = StandardInstruments.guitarDropD
    let dadgad = StandardInstruments.guitarDADGAD
    let banjo = StandardInstruments.banjoOpenG
    let lute = StandardInstruments.renaissanceLuteG

    #expect(dropD.courses.first?.pitches == [AbsolutePitch(.d, octave: 2)])
    #expect(dadgad.courses.map { $0.pitches[0].pitchClass } == [.d, .a, .d, .g, .a, .d])
    #expect(banjo.courses.first?.pitches[0].octave == 4)
    #expect(banjo.courses[1].pitches[0].octave == 3)
    #expect(lute.courses.first?.pitches.count == 2)
    #expect(lute.courses.first?.pitches[0].octave != lute.courses.first?.pitches[1].octave)
}

@Test func guitarAdvertisesStandardDropDAndDADGAD() {
    let guitar = StandardInstruments.guitar
    #expect(guitar.defaultTuning == StandardInstruments.guitarStandard.id)
    #expect(guitar.tunings.contains(StandardInstruments.guitarDropD.id))
    #expect(guitar.tunings.contains(StandardInstruments.guitarDADGAD.id))
}

@Test func instrumentValidationReportsInvalidTargetsAndModels() {
    let profile = InstrumentProfileDefinition(
        id: "profile:broken",
        version: "0.1",
        actuators: [.init("keys", count: 0)],
        interactions: [.init("press", targets: ["buttons"])]
    )
    let catalog = InstrumentCatalog(
        profiles: [profile],
        models: [.init(id: "model:broken", name: "Broken", profile: "profile:missing")]
    )

    let diagnostics = InstrumentCatalogValidator().validate(catalog)
    #expect(diagnostics.count == 3)
}
