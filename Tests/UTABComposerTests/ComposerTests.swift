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

@Test func semanticExpressionsHaveStableExplicitAndStructuralIdentities() {
    let first = MusicalExpression.rest(.quarter, id: "expression:first")
    let second = MusicalExpression.rest(.half, id: "expression:second")
    let sequenceA = MusicalExpression.sequence([first, second])
    let sequenceB = MusicalExpression.sequence([first, second])

    #expect(first.id == "expression:first")
    #expect(sequenceA.id == sequenceB.id)
    #expect(sequenceA.id != MusicalExpression.sequence([second, first]).id)

    let phraseA = Phrase("opening", bars: [.init(first)])
    let phraseB = Phrase("opening", bars: [.init(first)])
    #expect(phraseA.id == phraseB.id)
}

@Test func unresolvedReferencesAndRepetitionPreserveSemanticIntent() {
    let note = MusicalExpression.note(
        .absolute(.init(.c, octave: 4)),
        duration: .quarter,
        id: "expression:note"
    )
    let repeated = MusicalExpression.repeated(count: 4, note)
    let reference = MusicalExpression.reference("phrase:opening")

    #expect(repeated.duration == .whole)
    #expect(reference.duration == nil)

    guard case .repeated(let count, let operand) = repeated.kind else {
        Issue.record("Expected a repeated semantic expression")
        return
    }
    #expect(count == 4)
    #expect(operand.id == note.id)
}

@Test func actuatorAndTechniqueExpressionsRemainTypedBeforeLowering() {
    let source = MusicalExpression.actuator(
        .init(
            action: "pluck",
            target: .init(group: "strings", member: "2", position: 5),
            duration: .eighth,
            soundingPitch: .absolute(.init(.e, octave: 4))
        ),
        id: "expression:pluck"
    )
    let destination = MusicalExpression.actuator(
        .init(
            action: "pluck",
            target: .init(group: "strings", member: "2", position: 7),
            duration: .eighth
        ),
        id: "expression:destination"
    )
    let hammerOn = MusicalExpression.technique(
        .init("hammerOn", form: .transition, operands: [source, destination])
    )

    #expect(source.duration == .eighth)
    #expect(hammerOn.duration == .quarter)

    guard case .technique(let application) = hammerOn.kind else {
        Issue.record("Expected a technique application")
        return
    }
    #expect(application.form == .transition)
    #expect(application.operands.map(\.id) == [source.id, destination.id])
}

@Test func nameResolutionProducesTypedReferencesWithoutMutatingSemanticInput() {
    let phrase = Phrase("opening", bars: [
        .init(MusicalExpression.rest(.whole, id: "expression:opening")),
    ])
    let section = Section("verse", duration: .whole, parts: [
        .init(instrument: "piano", voices: [
            .init("melody", content: [.phrase("opening")]),
        ]),
    ])
    let composition = Composition(
        title: "Resolved",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [phrase],
        sections: [section]
    )

    let result = NameResolutionStage().run(composition)

    #expect(result.succeeded)
    #expect(result.output?.source == composition)
    #expect(result.output?.declarations[phrase.id]?.kind == .phrase)

    guard case .reference(let reference) = result.output?.sections.first?.parts.first?.voices.first?.content.first else {
        Issue.record("Expected the legacy phrase name to become a typed reference")
        return
    }
    #expect(reference.declaration.id == phrase.id)
    #expect(reference.declaration.kind == .phrase)
}

@Test func nameResolutionBindsExpressionReferencesAndRejectsInvalidKinds() {
    let phrase = Phrase("opening", expression: .rest(.whole, id: "expression:opening"))
    let section = Section("verse", duration: .whole, parts: [
        .init(instrument: "piano", voices: [
            .init("melody", content: [
                .expression(.reference("section:verse", id: "expression:bad-reference")),
            ]),
        ]),
    ])
    let composition = Composition(
        title: "Invalid reference",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [phrase],
        sections: [section]
    )

    let result = NameResolutionStage().run(composition)

    #expect(!result.succeeded)
    #expect(result.output == nil)
    #expect(result.diagnostics.contains { $0.message.contains("is not valid here") })
}

@Test func nameResolutionDiagnosesRecursivePhraseReferences() {
    let first = Phrase(
        "first",
        expression: .reference("phrase:second", id: "expression:first-to-second")
    )
    let second = Phrase(
        "second",
        expression: .reference("phrase:first", id: "expression:second-to-first")
    )
    let composition = Composition(
        title: "Recursive",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [first, second],
        sections: []
    )

    let result = NameResolutionStage().run(composition)

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("Recursive phrase reference") })
}

@Test func expansionEliminatesPhraseReferencesAndRepetitionWithStableOccurrences() {
    let note = MusicalExpression.note(
        .absolute(.init(.c, octave: 4)),
        duration: .quarter,
        id: "expression:repeated-note"
    )
    let phrase = Phrase(
        "opening",
        expression: .repeated(count: 2, note, id: "expression:repeat-opening")
    )
    let section = Section("verse", duration: .half, parts: [
        .init(instrument: "piano", voices: [
            .init("melody", content: [.reference(phrase.id)]),
        ]),
    ])
    let composition = Composition(
        title: "Expansion",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [phrase],
        sections: [section]
    )

    guard let resolved = NameResolutionStage().run(composition).output else {
        Issue.record("Expected name resolution to succeed")
        return
    }
    let firstResult = ReferenceExpansionStage().run(resolved)
    let secondResult = ReferenceExpansionStage().run(resolved)
    guard let firstVoice = firstResult.output?.sections.first?.parts.first?.voices.first,
          let secondVoice = secondResult.output?.sections.first?.parts.first?.voices.first else {
        Issue.record("Expected expansion to produce a voice")
        return
    }

    let firstLeaves = leafProvenances(in: firstVoice.expression)
    let secondLeaves = leafProvenances(in: secondVoice.expression)

    #expect(firstResult.succeeded)
    #expect(firstVoice.expression.duration == .half)
    #expect(firstLeaves.count == 2)
    #expect(firstLeaves[0].originID == note.id)
    #expect(firstLeaves[0].ancestry.contains(phrase.id))
    #expect(firstLeaves[0].ancestry.contains("expression:repeat-opening"))
    #expect(firstLeaves[0].occurrenceID != firstLeaves[1].occurrenceID)
    #expect(firstLeaves.map(\.occurrenceID) == secondLeaves.map(\.occurrenceID))
}

@Test func expansionCreatesDistinctStableSectionOccurrencesInMain() {
    let section = Section("verse", parts: [])
    let sectionReference = MusicalExpression.reference(section.id, id: "expression:verse-reference")
    let main = MusicalExpression.repeated(count: 2, sectionReference, id: "expression:repeat-verse")
    let composition = Composition(
        title: "Arrangement",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [section],
        main: main
    )

    guard let resolved = NameResolutionStage().run(composition).output,
          let expanded = ReferenceExpansionStage().run(resolved).output?.main,
          case .sequence(let occurrences) = expanded.kind else {
        Issue.record("Expected a repeated section arrangement")
        return
    }

    let sectionOccurrences = occurrences.compactMap { arrangement -> SectionOccurrence? in
        guard case .section(let occurrence) = arrangement.kind else { return nil }
        return occurrence
    }
    #expect(sectionOccurrences.count == 2)
    #expect(sectionOccurrences[0].sectionID == section.id)
    #expect(sectionOccurrences[0].occurrenceID != sectionOccurrences[1].occurrenceID)
}

@Test func expansionRejectsNegativeRepetitionCounts() {
    let phrase = Phrase(
        "invalid",
        expression: .repeated(count: -1, .rest(.quarter), id: "expression:negative-repeat")
    )
    let composition = Composition(
        title: "Invalid repetition",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [phrase],
        sections: []
    )

    guard let resolved = NameResolutionStage().run(composition).output else {
        Issue.record("Expected name resolution to succeed before expansion validation")
        return
    }
    let result = ReferenceExpansionStage().run(resolved)
    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("must not be negative") })
}

private func leafProvenances(in expression: ExpandedExpression) -> [ExpressionProvenance] {
    switch expression.kind {
    case .sequence(let children), .parallel(let children):
        return children.flatMap { leafProvenances(in: $0) }
    case .technique(let application):
        return application.operands.flatMap { leafProvenances(in: $0) }
    case .note, .rest, .chord, .actuator:
        return [expression.provenance]
    }
}

@Test func temporalResolutionSchedulesSequenceAndParallelWithRationalOffsets() {
    let expression = MusicalExpression.sequence([
        .rest(.quarter, id: "expression:first"),
        .parallel([
            .rest(.eighth, id: "expression:parallel-short"),
            .rest(.half, id: "expression:parallel-long"),
        ], id: "expression:parallel"),
    ], id: "expression:root")
    let section = Section("timing", duration: MusicalDuration(3, 4), parts: [
        .init(instrument: "test", voices: [.init("voice", content: [.expression(expression)])]),
    ])
    let composition = Composition(
        title: "Timing",
        meter: .init(3, 4),
        tempo: 100,
        phrases: [],
        sections: [section]
    )

    guard let resolved = NameResolutionStage().run(composition).output,
          let expanded = ReferenceExpansionStage().run(resolved).output,
          let timed = TemporalResolutionStage().run(expanded).output,
          let voice = timed.sections.first?.parts.first?.voices.first,
          case .sequence(let voiceChildren) = voice.expression.kind,
          case .sequence(let rootChildren) = voiceChildren.first?.kind,
          case .parallel(let parallelChildren) = rootChildren.last?.kind else {
        Issue.record("Expected a scheduled sequence containing a parallel expression")
        return
    }

    #expect(rootChildren[0].offset == .zero)
    #expect(rootChildren[1].offset == .quarter)
    #expect(parallelChildren.allSatisfy { $0.offset == .quarter })
    #expect(rootChildren[1].duration == .half)
    #expect(voice.expression.duration == MusicalDuration(3, 4))
}

@Test func producesResolvedTwinkleDebugTimelineWithBarProvenance() {
    let melody = Phrase("melodyA") {
        Bar {
            Degree(1, octave: 4, .quarter)
            Degree(1, octave: 4, .quarter)
            Degree(5, octave: 4, .quarter)
            Degree(5, octave: 4, .quarter)
        }
    }
    let tonic = Chord(.c, .major, .whole)
    let twinkle = Song(
        "Twinkle Timeline",
        meter: .init(4, 4),
        tempo: 100,
        scale: .init(.c, .major)
    ) {
        melody
        Section("verse", duration: .whole) {
            Instrument("piano") {
                Voice("right hand") { Play("melodyA") }
                Voice("left hand") { tonic }
            }
            Instrument("guitar") {
                Voice("chords") { tonic }
            }
            Instrument("voice") {
                Voice("melody") { Play("melodyA") }
            }
        }
    }

    guard let named = NameResolutionStage().run(twinkle).output,
          let expanded = ReferenceExpansionStage().run(named).output,
          let timed = TemporalResolutionStage().run(expanded).output,
          let pitched = PitchResolutionStage().run(timed).output else {
        Issue.record("Expected the Twinkle compiler stages to succeed")
        return
    }

    let debug = TimelineDebugRenderer().render(pitched)
    let rightHand = pitched.sections[0].parts[0].voices[0]
    let provenance = pitchResolvedLeafProvenances(in: rightHand.expression)

    #expect(debug.contains("composition Twinkle Timeline"))
    #expect(debug.contains("section verse duration=1/1"))
    #expect(debug.contains("voice right hand duration=1/1"))
    #expect(debug.contains("note @1[4] -> C4 at=0/1 duration=1/4"))
    #expect(debug.contains("chord root=0 quality=major"))
    #expect(provenance.count == 4)
    #expect(provenance.allSatisfy { $0.ancestry.contains(melody.id) })
    #expect(provenance.allSatisfy { item in melody.bars.contains { item.ancestry.contains($0.id) } })
}

private func pitchResolvedLeafProvenances(in expression: PitchResolvedExpression) -> [ExpressionProvenance] {
    switch expression.kind {
    case .sequence(let children), .parallel(let children):
        return children.flatMap { pitchResolvedLeafProvenances(in: $0) }
    case .technique(let application):
        return application.operands.flatMap { pitchResolvedLeafProvenances(in: $0) }
    case .note, .rest, .chord, .actuator:
        return [expression.provenance]
    }
}

@Test func resolvesScaleRelativePitch() {
    let cMajor = Scale(.c, .major)
    #expect(cMajor.resolve(degree: 1, octave: 4) == AbsolutePitch(.c, octave: 4))
    #expect(cMajor.resolve(degree: 5, octave: 4) == AbsolutePitch(.g, octave: 4))
    #expect(cMajor.resolve(degree: 8, octave: 4) == AbsolutePitch(.c, octave: 5))
}

@Test func preservesEnharmonicSpellingWithoutForcingAcousticDistinction() {
    let fSharp = AbsolutePitch(.init(.f, accidental: 1), octave: 4)
    let gFlat = AbsolutePitch(.init(.g, accidental: -1), octave: 4)

    #expect(fSharp.spelling != gFlat.spelling)
    #expect(fSharp.isAcousticallyEquivalent(to: gFlat))

    let relativeChord = ChordSymbol(scaleDegree: 1, .major)
    #expect(relativeChord.root == .scaleDegree(1))
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
