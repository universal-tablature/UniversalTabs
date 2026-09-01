import Foundation
import Testing
import UTABComposerCore
import UTABComposerDSL
import UTABComposerText
import UTABInstrumentLibrary
import UTABInstruments
import UTABLowering
import UniversalTabs

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

@Test func minimalLowererProducesValidDeterministicUTabDocument() throws {
    let melody = Phrase("melody") {
        Bar {
            Degree(1, octave: 4, .quarter)
            Degree(2, octave: 4, .quarter)
            Degree(3, octave: 4, .quarter)
            Degree(5, octave: 4, .quarter)
        }
    }
    let composition = Song(
        "Lowered melody",
        meter: .init(4, 4),
        tempo: 96,
        scale: .init(.c, .major)
    ) {
        melody
        Section("verse", duration: .whole) {
            Instrument("piano") {
                Voice("melody") { Play("melody") }
            }
        }
    }

    guard let realized = compileToRealized(composition, bindings: ["piano": testInstance("piano", model: StandardInstruments.piano.id)]) else {
        Issue.record("Expected the semantic pipeline to succeed")
        return
    }
    let first = MinimalUTabLoweringStage().run(realized)
    let second = MinimalUTabLoweringStage().run(realized)
    guard let document = first.output, let secondDocument = second.output else {
        Issue.record("Expected minimal UTAB lowering to succeed: \(first.diagnostics)")
        return
    }

    #expect(first.succeeded)
    #expect(UTabValidator().validate(document).isEmpty)
    #expect(document.setup.sections?.first?.id == "section:verse")
    #expect(document.setup.arrangement?.count == 1)
    #expect(document.tracks.count == 1)
    #expect(document.tracks.first?.parts?.first?.events.count == 4)
    #expect(document.tracks.first?.parts?.first?.events[0].at.musical?.beat == 1)
    #expect(document.tracks.first?.parts?.first?.events[1].at.musical?.beat == 2)
    #expect(document.tracks.first?.parts?.first?.events[0].parameters?["_source"] != nil)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(document) == encoder.encode(secondDocument))
}

@Test func minimalLowererPreservesExactActuatorTargets() {
    let exact = Actuate(
        "pluck",
        group: "strings",
        member: "2",
        position: 5,
        duration: .quarter,
        soundingPitch: .absolute(.init(.e, octave: 4))
    )
    let composition = Composition(
        title: "Exact actuator",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [
            .init("verse", duration: .quarter, parts: [
                .init(instrument: "guitar", voices: [.init("part", content: [.expression(exact)])]),
            ]),
        ]
    )

    guard let realized = compileToRealized(composition, bindings: ["guitar": testInstance("guitar", model: StandardInstruments.guitar.id)]),
          let document = MinimalUTabLoweringStage().run(realized).output,
          let event = document.tracks.first?.parts?.first?.events.first else {
        Issue.record("Expected exact actuator lowering to succeed")
        return
    }

    #expect(event.action == "pluck")
    #expect(event.target == "strings[2]")
    #expect(event.parameters?["position"] == .number(5))
    #expect(UTabValidator().validate(document).isEmpty)
}

@Test func realizationRejectsPhysicalPositionWithMismatchedPitch() {
    let impossible = Actuate(
        "pluck",
        group: "strings",
        member: "2",
        position: 5,
        duration: .quarter,
        soundingPitch: .absolute(.init(.f, octave: 4))
    )
    let composition = Composition(
        title: "Mismatched position",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init("verse", duration: .quarter, parts: [
            .init(instrument: "guitar", voices: [.init("part", content: [.expression(impossible)])]),
        ])]
    )
    guard let pitched = compileToPitchResolved(composition) else {
        Issue.record("Expected pitch resolution to succeed")
        return
    }
    let result = InstrumentRealizationStage().run(.init(
        composition: pitched,
        catalog: StandardInstruments.catalog,
        instrumentBindings: ["guitar": testInstance("guitar", model: StandardInstruments.guitar.id)]
    ))

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("produces acoustic pitch") })
}

@Test func frettedStringRealizationLowersAbstractChordToDistinctStrings() {
    let composition = Composition(
        title: "Needs voicing",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [
            .init("verse", duration: .whole, parts: [
                .init(instrument: "guitar", voices: [
                    .init("chords", content: [.expression(Chord(.c, .major, .whole))]),
                ]),
            ]),
        ]
    )

    guard let realized = compileToRealized(composition, bindings: ["guitar": testInstance("guitar", model: StandardInstruments.guitar.id)]),
          let document = MinimalUTabLoweringStage().run(realized).output,
          let events = document.tracks.first?.parts?.first?.events else {
        Issue.record("Expected guitar chord realization and lowering to succeed")
        return
    }

    #expect(events.count == 3)
    #expect(Set(events.compactMap(\.target)).count == 3)
    #expect(events.allSatisfy { $0.action == "pluck" })
    #expect(UTabValidator().validate(document).isEmpty)
}

@Test func keyboardRealizationUsesConcurrentKeysForChords() {
    let composition = Composition(
        title: "Keyboard chord",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [
            .init("verse", duration: .whole, parts: [
                .init(instrument: "piano", voices: [
                    .init("left hand", content: [
                        .expression(Chord(.c, .major, .whole, constraints: [.group("left hand")])),
                    ]),
                ]),
            ]),
        ]
    )

    guard let realized = compileToRealized(composition, bindings: ["piano": testInstance("piano", model: StandardInstruments.piano.id)]),
          let document = MinimalUTabLoweringStage().run(realized).output,
          let events = document.tracks.first?.parts?.first?.events else {
        Issue.record("Expected keyboard chord realization to succeed")
        return
    }

    #expect(events.count == 3)
    #expect(events.allSatisfy { $0.action == "press" })
    #expect(events.allSatisfy { $0.at.musical?.measure == 1 && $0.at.musical?.beat == 1 })
    #expect(Set(events.compactMap(\.target)).count == 3)
}

@Test func realizationRequiresExplicitInstrumentBindings() {
    let composition = Composition(
        title: "Unbound",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init("verse", duration: .quarter, parts: [
            .init(instrument: "mystery", voices: [.init("voice", content: [.expression(C4(.quarter))])]),
        ])]
    )
    guard let pitched = compileToPitchResolved(composition) else {
        Issue.record("Expected pitch resolution to succeed")
        return
    }
    let result = InstrumentRealizationStage().run(.init(
        composition: pitched,
        catalog: StandardInstruments.catalog,
        instrumentBindings: [:]
    ))

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("No instrument binding") })
}

private func compileToPitchResolved(_ composition: Composition) -> PitchResolvedComposition? {
    guard let named = NameResolutionStage().run(composition).output,
          let expanded = ReferenceExpansionStage().run(named).output,
          let timed = TemporalResolutionStage().run(expanded).output else { return nil }
    return PitchResolutionStage().run(timed).output
}

private func compileToRealized(
    _ composition: Composition,
    bindings: [String: InstrumentInstanceDefinition]
) -> RealizedComposition? {
    guard let pitched = compileToPitchResolved(composition) else { return nil }
    return InstrumentRealizationStage().run(.init(
        composition: pitched,
        catalog: StandardInstruments.catalog,
        instrumentBindings: bindings
    )).output
}

private func testInstance(_ id: InstrumentID, model: InstrumentID, name: String? = nil) -> InstrumentInstanceDefinition {
    .init(id: id, name: name, model: model)
}

@Test func compilerFacadeLowersFullTwinkleWithDistinctGuitarInstances() throws {
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
        "Twinkle End to End",
        meter: .init(4, 4),
        tempo: 100,
        scale: .init(.c, .major)
    ) {
        melody
        Section("verse", duration: .whole) {
            Instrument("piano") {
                Voice("right hand") { Play("melodyA") }
                Voice("left hand", constraints: [.group("left hand")]) { tonic }
            }
            Instrument("Rhythm Guitar") {
                Voice("rhythm") { tonic }
            }
            Instrument("Lead Guitar") {
                Voice("lead") { Play("melodyA") }
            }
            Instrument("voice") {
                Voice("melody") { Play("melodyA") }
            }
        }
    }
    let compiler = UTABCompositionCompiler(
        catalog: StandardInstruments.catalog,
        instrumentBindings: [
            "piano": testInstance("piano_i", model: StandardInstruments.piano.id, name: "Piano"),
            "Rhythm Guitar": testInstance("guitar_i", model: StandardInstruments.guitar.id, name: "Rhythm Guitar"),
            "Lead Guitar": testInstance("guitar_ii", model: StandardInstruments.guitar.id, name: "Lead Guitar"),
            "voice": testInstance("voice_i", model: StandardInstruments.voice.id, name: "Vocals"),
        ]
    )

    let first = compiler.compile(twinkle)
    let second = compiler.compile(twinkle)
    guard let document = first.output, let repeatedDocument = second.output else {
        Issue.record("Expected full Twinkle compilation to succeed: \(first.diagnostics)")
        return
    }

    #expect(first.succeeded)
    #expect(UTabValidator().validate(document).isEmpty)
    #expect(Set(document.setup.instruments.map(\.id)) == Set(["piano_i", "guitar_i", "guitar_ii", "voice_i"]))
    #expect(document.setup.instruments.first { $0.id == "guitar_i" }?.name == "Rhythm Guitar")
    #expect(document.setup.instruments.first { $0.id == "guitar_ii" }?.name == "Lead Guitar")
    #expect(document.tracks.contains { $0.instrument == "guitar_i" })
    #expect(document.tracks.contains { $0.instrument == "guitar_ii" })
    #expect(document.tracks.count == 5)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let canonical = try encoder.encode(document)
    let repeatedCanonical = try encoder.encode(repeatedDocument)
    #expect(canonical == repeatedCanonical)
    #expect(stableFingerprint(canonical) == "bbb0b67c9496391")
}

private func stableFingerprint(_ data: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

@Test func resolvesScaleRelativePitch() {
    let cMajor = Scale(.c, .major)
    #expect(cMajor.resolve(degree: 1, octave: 4) == AbsolutePitch(.c, octave: 4))
    #expect(cMajor.resolve(degree: 5, octave: 4) == AbsolutePitch(.g, octave: 4))
    #expect(cMajor.resolve(degree: 8, octave: 4) == AbsolutePitch(.c, octave: 5))
}

@Test func resolvesOudMaqamatWithMicrotonalDegrees() throws {
    let rast = Scale(.c, .custom(name: "MaqamRast", centIntervals: [0, 200, 350, 500, 700, 900, 1_050]))
    let rastThird = try #require(rast.resolve(degree: 3, octave: 4))
    let rastSeventh = try #require(rast.resolve(degree: 7, octave: 4))
    let bayati = Scale(.d, .custom(name: "MaqamBayati", centIntervals: [0, 150, 300, 500, 700, 800, 1_000]))
    let bayatiSecond = try #require(bayati.resolve(degree: 2, octave: 4))

    #expect(rastThird.pitchClass == .eFlat)
    #expect(rastThird.spelling.tuningOffsetCents == 50)
    #expect(rastThird.acousticCents - AbsolutePitch(.c, octave: 4).acousticCents == 350)
    #expect(rastSeventh.acousticCents - AbsolutePitch(.c, octave: 4).acousticCents == 1_050)
    #expect(bayatiSecond.acousticCents - AbsolutePitch(.d, octave: 4).acousticCents == 150)
    #expect(!rastThird.isAcousticallyEquivalent(to: AbsolutePitch(.eFlat, octave: 4)))
}

@Test func textComposerAcceptsMaqamScaleAndResolvesRelativePitch() throws {
    let source = TextSource(
        """
        title "Bayati on Oud"
        import instruments.oud.arabic
        import instruments.lyre.sammu
        meter 4/4
        tempo 80
        scale D MaqamBayati

        phrase melody {
            @2[4] w
        }
        """,
        fileID: "bayati-oud.utab"
    )
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let lowered = TextSemanticLowerer().lower(loaded.modules)
    let composition = try #require(lowered.composition)
    let scale = try #require(composition.scale)

    #expect(lowered.diagnostics.isEmpty)
    #expect(scale.kind == .custom(name: "MaqamBayati", centIntervals: [0, 150, 300, 500, 700, 800, 1_000]))
    #expect(scale.resolve(degree: 2, octave: 4)?.spelling.tuningOffsetCents == 50)
}

@Test func lutePublishesNonEqualMovableFretReference() throws {
    let source = TextSource(
        """
        import instruments.lute.renaissance
        title "Lute fret setup"
        meter 4/4
        tempo 60
        scale G LuteQuarterCommaMeantone
        """,
        fileID: "lute-frets.utab"
    )
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let lowered = TextSemanticLowerer().lower(loaded.modules)
    let compiled = TextInstrumentCatalogCompiler().compile(
        loaded.modules,
        extending: .init(profiles: [], models: [])
    )
    let scale = try #require(lowered.composition?.scale)
    let lute = try #require(compiled.catalog.models.first { $0.id == "instrument:lute:renaissance-six-course" })
    let frets = try #require(lute.geometry.first { $0.id == "frets" })
    guard case .scale(let scaleID) = frets.properties["scale"] else {
        Issue.record("Lute fret geometry should contain a typed scale reference")
        return
    }
    let catalogScale = try #require(compiled.catalog.scale(scaleID))

    #expect(loaded.succeeded)
    #expect(lowered.succeeded)
    #expect(compiled.succeeded)
    #expect(scale.kind.centIntervals == [0, 76, 193, 310, 386, 503, 579, 697, 814, 890, 1_007, 1_083])
    #expect(scale.kind.centIntervals != ScaleKind.major.centIntervals)
    #expect(catalogScale.name == "LuteQuarterCommaMeantone")
    #expect(catalogScale.centIntervals == scale.kind.centIntervals)
    #expect(compiled.scaleBindings["LuteQuarterCommaMeantone"] == scaleID)
    guard case .list(let options) = frets.properties["scales"] else {
        Issue.record("Lute fret geometry should publish selectable scale references")
        return
    }
    #expect(options.count == 4)
    #expect(options.allSatisfy { if case .scale = $0 { true } else { false } })
    #expect(InstrumentCatalogValidator().validate(compiled.catalog).isEmpty)
}

@Test func nineStringSammuUsesRelativeNidQablimReconstruction() throws {
    let source = TextSource(
        "module tests.sammu\nimport instruments.lyre.sammu\n",
        fileID: "sammu.utab"
    )
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let compiled = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))
    let model = try #require(compiled.catalog.models.first { $0.id.rawValue == "instrument:lyre:sammu:nine-string" })
    let tuning = try #require(compiled.catalog.tunings.first { $0.id.rawValue == "tuning:lyre:sammu:nid-qablim-d-relative" })

    #expect(loaded.succeeded)
    #expect(compiled.succeeded)
    #expect(model.defaultTuning == tuning.id)
    #expect(model.geometry.first { $0.id == "strings" }?.properties["count"] == .integer(9))
    #expect(tuning.courses.map { $0.pitches[0] } == [
        AbsolutePitch(.e, octave: 4), AbsolutePitch(.d, octave: 4),
        AbsolutePitch(.c, octave: 4), AbsolutePitch(.b, octave: 3),
        AbsolutePitch(.a, octave: 3), AbsolutePitch(.g, octave: 3),
        AbsolutePitch(.f, octave: 3), AbsolutePitch(.e, octave: 3),
        AbsolutePitch(.d, octave: 3),
    ])
}

@Test func instrumentCatalogRejectsInvalidAndMissingScales() {
    let catalog = InstrumentCatalog(
        scales: [.init(id: "scale:broken", name: "Broken", centIntervals: [10, 5])],
        profiles: [.init(id: "profile:test", version: "1", actuators: [], interactions: [])],
        models: [
            .init(
                id: "instrument:test",
                name: "Test",
                profile: "profile:test",
                geometry: [.init("frets", properties: ["scale": .scale("scale:missing")])]
            ),
        ]
    )
    let diagnostics = InstrumentCatalogValidator().validate(catalog)

    #expect(diagnostics.contains { $0.path == "scales[0].centIntervals" })
    #expect(diagnostics.contains { $0.path == "models[0].geometry.frets.scale" })
}

@Test func preservesEnharmonicSpellingWithoutForcingAcousticDistinction() {
    let fSharp = AbsolutePitch(.init(.f, accidental: 1), octave: 4)
    let gFlat = AbsolutePitch(.init(.g, accidental: -1), octave: 4)

    #expect(fSharp.spelling != gFlat.spelling)
    #expect(fSharp.isAcousticallyEquivalent(to: gFlat))

    let relativeChord = ChordSymbol(scaleDegree: 1, .major)
    #expect(relativeChord.root == .scaleDegree(1))
}

@Test func microtonalPitchFrequencyAndTranspositionPreserveCents() {
    let concertA = AbsolutePitch.concertA
    let quarterSharpA = concertA.transposed(cents: 50)
    let meantoneStep = AbsolutePitch(.g, octave: 3).transposed(cents: 76)

    #expect(abs(concertA.frequency() - 440) < 0.000_001)
    #expect(abs(quarterSharpA.frequency() - 440 * pow(2, 50.0 / 1_200)) < 0.000_001)
    #expect(quarterSharpA.cents(relativeTo: concertA) == 50)
    #expect(abs(quarterSharpA.spelling.tuningOffsetCents) == 50)
    #expect(meantoneStep.acousticCents - AbsolutePitch(.g, octave: 3).acousticCents == 76)
    #expect(AbsolutePitch(acousticCents: meantoneStep.acousticCents) == meantoneStep)
}

@Test func minimalLoweringPreservesMicrotonalPitchAsExactFrequency() throws {
    let microtonalPitch = AbsolutePitch.concertA.transposed(cents: 50)
    let composition = Composition(
        title: "Microtonal frequency",
        meter: .init(4, 4),
        tempo: 80,
        phrases: [],
        sections: [.init("verse", duration: .whole, parts: [
            .init(instrument: "voice", voices: [
                .init("melody", content: [
                    .expression(.note(.absolute(microtonalPitch), duration: .whole)),
                ]),
            ]),
        ])]
    )
    let result = UTABCompositionCompiler(
        catalog: StandardInstruments.catalog,
        instrumentBindings: ["voice": testInstance("voice_i", model: StandardInstruments.voice.id)]
    ).compile(composition)
    let document = try #require(result.output)
    let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

    #expect(result.succeeded)
    #expect(json.contains("frequencyHz"))
    #expect(json.contains("452.892"))
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
    #expect(catalog.scales.count == 11)
    #expect(catalog.tunings.count == 20)
    #expect(catalog.profiles.count == 19)
    #expect(catalog.models.count == 50)
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func luteFamilyPublishesHistoricalConstructionsAndTunings() throws {
    let catalog = StandardInstruments.catalog
    let expected: [(String, Int, Int)] = [
        ("instrument:lute:renaissance-six-course", 6, 8),
        ("instrument:lute:renaissance-eight-course", 8, 9),
        ("instrument:lute:renaissance-ten-course", 10, 9),
        ("instrument:lute:baroque-eleven-course", 11, 11),
        ("instrument:lute:baroque-thirteen-course", 13, 11),
        ("instrument:archlute:fourteen-course", 14, 10),
        ("instrument:theorbo:fourteen-course-a", 14, 8),
        ("instrument:vihuela:renaissance-six-course", 6, 10),
    ]

    for (id, courses, frets) in expected {
        let model = try #require(catalog.models.first { $0.id.rawValue == id })
        #expect(model.geometry.first { $0.id == "courses" }?.properties["count"] == .integer(courses))
        #expect(model.geometry.first { $0.id == "frets" }?.properties["count"] == .integer(frets))
        #expect(model.geometry.first { $0.id == "frets" }?.properties["tastiniSupported"] == .boolean(true))
        let tuning = try #require(model.defaultTuning.flatMap { tuningID in catalog.tunings.first { $0.id == tuningID } })
        #expect(tuning.courses.count == courses)
    }

    let theorbo = try #require(catalog.models.first { $0.id == "instrument:theorbo:fourteen-course-a" })
    #expect(theorbo.geometry.first { $0.id == "courses" }?.properties["reentrantTopCourses"] == .integer(2))
    #expect(theorbo.geometry.first { $0.id == "courses" }?.properties["diapasons"] == .integer(8))
}

@Test func standardLibraryIncludesWindAndPercussionFamilies() {
    let catalog = StandardInstruments.catalog
    let expectedModelIDs = [
        "instrument:recorder:soprano",
        "instrument:flute:concert-c",
        "instrument:clarinet:b-flat",
        "instrument:oboe:standard",
        "instrument:percussion:drum-kit",
        "instrument:percussion:marimba",
        "instrument:percussion:timpani",
    ]

    for id in expectedModelIDs {
        #expect(catalog.models.contains { $0.id.rawValue == id })
    }
}

@Test func recorderFingeringMapsAreExplicitExtensibleAndUnknownByDefault() throws {
    let standard = StandardInstruments.catalog
    let recorder = try #require(standard.models.first { $0.id.rawValue == "instrument:recorder:soprano" })
    let baroque = try #require(recorder.defaultFingering)

    #expect(standard.fingeringResult(for: "11111111", in: baroque) == .pitch(.init(.c, octave: 5)))
    #expect(standard.fingeringResult(for: "10101010", in: baroque) == nil)

    let source = TextSource(
        """
        module composer.recorder
        import instruments.wind

        extension SopranoRecorder {
            fingering experimental {
                id "fingering:recorder:soprano:experimental"
                name "Experimental soprano recorder"
                actuators toneHoles
                extends "fingering:recorder:soprano:baroque"
                bitOrder thumb, hole1, hole2, hole3, hole4, hole5, hole6, hole7

                effect multiphonic "10101010" alternate "composer-defined"
            }
        }

        instrument recorder : SopranoRecorder fingering "fingering:recorder:soprano:experimental" as "Solo Recorder"
        """,
        fileID: "experimental-recorder.utab"
    )
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let compiled = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))
    let experimental = InstrumentID(rawValue: "fingering:recorder:soprano:experimental")

    #expect(loaded.succeeded)
    #expect(compiled.succeeded)
    #expect(InstrumentCatalogValidator().validate(compiled.catalog).isEmpty)
    #expect(compiled.catalog.fingeringResult(for: "10101010", in: experimental) == .effect("multiphonic"))
    #expect(compiled.catalog.fingeringResult(for: "11111111", in: experimental) == .pitch(.init(.c, octave: 5)))
    #expect(compiled.catalog.fingeringResult(for: "00000000", in: experimental) == nil)
    let rootModule = loaded.modules.first { $0.isRoot }
    let root = try #require(rootModule)
    let declarations = TextSemanticLowerer().lower(root.syntax).instruments
    let resolved = TextInstrumentResolver().resolve(declarations, in: compiled.catalog, modelBindings: compiled.modelBindings)
    #expect(resolved.succeeded)
    #expect(resolved.bindings["recorder"]?.fingering == experimental)
}

@Test func fingeringLookupPrefersSpecificPatternsAndListsPitchAlternatives() throws {
    let modelID = InstrumentID(rawValue: "instrument:test:wind")
    let profileID = InstrumentID(rawValue: "profile:test:wind")
    let mapID = InstrumentID(rawValue: "fingering:test:wind")
    let map = FingeringDefinition(
        id: mapID,
        name: "Test map",
        model: modelID,
        actuatorGroup: "holes",
        bitOrder: ["a", "b", "c"],
        entries: [
            .init(pattern: "1xx", result: .effect("noise")),
            .init(pattern: "101", result: .pitch(.init(.c, octave: 5))),
            .init(pattern: "001", result: .pitch(.init(.c, octave: 5)), preference: .alternate, label: "soft"),
        ]
    )
    let catalog = InstrumentCatalog(
        fingerings: [map],
        profiles: [.init(id: profileID, version: "1", actuators: [.init("holes", count: 3, control: .orderedBitset(width: 3))], interactions: [])],
        models: [.init(id: modelID, name: "Test wind", profile: profileID, fingerings: [mapID], defaultFingering: mapID)]
    )

    #expect(catalog.fingeringResult(for: "101", in: mapID) == .pitch(.init(.c, octave: 5)))
    #expect(catalog.fingeringResult(for: "110", in: mapID) == .effect("noise"))
    let alternatives = catalog.fingerings(for: .init(.c, octave: 5), in: mapID)
    #expect(alternatives.map(\.pattern) == ["101", "001"])
    #expect(alternatives.map(\.preference) == [.preferred, .alternate])
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func standardRecorderFamilyProvidesYamahaBaroqueAndGermanMapIdentities() throws {
    let catalog = StandardInstruments.catalog
    let soprano = try #require(catalog.models.first { $0.id.rawValue == "instrument:recorder:soprano" })
    let alto = try #require(catalog.models.first { $0.id.rawValue == "instrument:recorder:alto" })
    let sopranoBaroque = InstrumentID(rawValue: "fingering:recorder:soprano:baroque")
    let sopranoGerman = InstrumentID(rawValue: "fingering:recorder:soprano:german")
    let altoBaroque = InstrumentID(rawValue: "fingering:recorder:alto:baroque")

    #expect(soprano.defaultFingering == sopranoBaroque)
    #expect(Set(soprano.fingerings) == [sopranoBaroque, sopranoGerman])
    #expect(alto.defaultFingering == altoBaroque)
    #expect(alto.fingerings == [altoBaroque])
    #expect(catalog.fingeringResult(for: "11111011", in: sopranoBaroque) == .pitch(.init(.f, octave: 5)))
    #expect(catalog.fingeringResult(for: "11111000", in: sopranoGerman) == .pitch(.init(.f, octave: 5)))
    #expect(catalog.fingeringResult(for: "11111011", in: altoBaroque) == .pitch(.init(.bFlat, octave: 4)))
    #expect(catalog.fingeringResult(for: "h1111100", in: sopranoBaroque) == .pitch(.init(.e, octave: 6)))
    #expect(catalog.fingeringResult(for: "h1111100", in: sopranoGerman) == .pitch(.init(.e, octave: 6)))
    #expect(catalog.fingeringResult(for: "h1111100", in: altoBaroque) == .pitch(.init(.a, octave: 5)))
}

@Test func standardClarinetMapCoversChalumeauRegisterKeyAndAlternateFingerings() throws {
    let catalog = StandardInstruments.catalog
    let clarinet = try #require(catalog.models.first { $0.id.rawValue == "instrument:clarinet:b-flat" })
    let boehm = try #require(clarinet.defaultFingering)
    let keys = try #require(clarinet.geometry.first { $0.id == "keys" })

    #expect(boehm == "fingering:clarinet:b-flat:boehm")
    #expect(keys.properties["system"] == .text("Boehm"))
    #expect(keys.properties["registerInterval"] == .text("twelfth"))
    #expect(catalog.fingeringResult(for: "011111110001000000", in: boehm) == .pitch(.init(.e, octave: 3)))
    #expect(catalog.fingeringResult(for: "111111110001000000", in: boehm) == .pitch(.init(.b, octave: 4)))
    #expect(catalog.fingeringResult(for: "100000000100000000", in: boehm) == .pitch(.init(.bFlat, octave: 4)))

    let bFlatAlternatives = catalog.fingerings(for: .init(.bFlat, octave: 4), in: boehm)
    #expect(bFlatAlternatives.map(\.preference) == [.preferred, .alternate])
    #expect(bFlatAlternatives.last?.label == "side-key")
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func standardFluteMapsCoverRegistersAlternatesAndPartialOpenHoles() throws {
    let catalog = StandardInstruments.catalog
    let flute = try #require(catalog.models.first { $0.id.rawValue == "instrument:flute:concert-c" })
    let closed = InstrumentID(rawValue: "fingering:flute:concert-c:boehm-closed-hole")
    let open = InstrumentID(rawValue: "fingering:flute:concert-c:boehm-open-hole")
    let holes = try #require(flute.geometry.first { $0.id == "toneHoles" })

    #expect(flute.defaultFingering == closed)
    #expect(Set(flute.fingerings) == [closed, open])
    #expect(holes.properties["openHoleKeys"] == .integer(5))
    #expect(catalog.fingeringResult(for: "111111000100000000", register: 1, in: closed) == .pitch(.init(.d, octave: 4)))
    #expect(catalog.fingeringResult(for: "111111000100000000", register: 2, in: closed) == .pitch(.init(.d, octave: 5)))
    #expect(catalog.fingeringResult(for: "111111000100000000", in: closed) == nil)

    let fSharpAlternatives = catalog.fingerings(for: .init(.fSharp, octave: 4), in: closed)
    #expect(fSharpAlternatives.map(\.preference) == [.preferred, .alternate])
    #expect(catalog.fingeringResult(for: "xh0000000000000000", in: open) == .effect("pitchShade"))
    #expect(catalog.fingeringResult(for: "xh0000000000000000", in: closed) == nil)
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func standardSaxophonesShareCompleteWrittenFingeringsAcrossTranspositions() throws {
    let catalog = StandardInstruments.catalog
    let alto = try #require(catalog.models.first { $0.id.rawValue == "instrument:saxophone:alto-e-flat" })
    let tenor = try #require(catalog.models.first { $0.id.rawValue == "instrument:saxophone:tenor-b-flat" })
    let altoMap = try #require(alto.defaultFingering)
    let tenorMap = try #require(tenor.defaultFingering)

    #expect(alto.profile == "profile:wind:saxophone")
    #expect(tenor.profile == "profile:wind:saxophone")
    #expect(catalog.fingeringResult(for: "0111111000000000010000", register: 1, in: altoMap) == .pitch(.init(.bFlat, octave: 3)))
    #expect(catalog.fingeringResult(for: "1111111000000000000000", register: 2, in: altoMap) == .pitch(.init(.d, octave: 5)))
    #expect(catalog.fingeringResult(for: "1000000000000100000000", register: 3, in: altoMap) == .pitch(.init(.d, octave: 6)))
    #expect(catalog.fingeringResult(for: "1111111000000000000000", register: 2, in: tenorMap) == .pitch(.init(.d, octave: 5)))

    let altoBFlat = catalog.fingerings(for: .init(.bFlat, octave: 4), in: altoMap)
    let tenorBFlat = catalog.fingerings(for: .init(.bFlat, octave: 4), in: tenorMap)
    #expect(altoBFlat.map(\.label) == [nil, "side-B-flat"])
    #expect(tenorBFlat.map(\.pattern) == altoBFlat.map(\.pattern))
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func standardTrumpetUsesValvesWithinExplicitHarmonicRegisters() throws {
    let catalog = StandardInstruments.catalog
    let trumpet = try #require(catalog.models.first { $0.id.rawValue == "instrument:trumpet:b-flat" })
    let fingering = try #require(trumpet.defaultFingering)
    let harmonics = try #require(trumpet.geometry.first { $0.id == "harmonics" })
    let slides = try #require(trumpet.geometry.first { $0.id == "tuningSlides" })

    #expect(catalog.fingeringResult(for: "000", register: 2, in: fingering) == .pitch(.init(.c, octave: 4)))
    #expect(catalog.fingeringResult(for: "000", register: 3, in: fingering) == .pitch(.init(.g, octave: 4)))
    #expect(catalog.fingeringResult(for: "000", register: 4, in: fingering) == .pitch(.init(.c, octave: 5)))
    #expect(catalog.fingeringResult(for: "000", register: 5, in: fingering) == .pitch(.init(.e, octave: 5)))
    #expect(catalog.fingeringResult(for: "000", register: 6, in: fingering) == .pitch(.init(.g, octave: 5)))
    #expect(catalog.fingeringResult(for: "000", register: 8, in: fingering) == .pitch(.init(.c, octave: 6)))
    #expect(catalog.fingeringResult(for: "000", in: fingering) == nil)

    let a3Alternatives = catalog.fingerings(for: .init(.a, octave: 3), in: fingering)
    #expect(a3Alternatives.map(\.pattern) == ["011", "001"])
    #expect(a3Alternatives.last?.label == "third-valve-use-slide")
    #expect(harmonics.properties["seventhPartialOffsetCents"] == .decimal(-31.17))
    #expect(slides.properties["thirdValve"] == .boolean(true))
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func tromboneSlideResolvesNamedAdjustablePositionsAndHarmonicPartials() throws {
    let catalog = StandardInstruments.catalog
    let tromboneID = InstrumentID(rawValue: "instrument:trombone:tenor-b-flat")
    let trombone = try #require(catalog.models.first { $0.id == tromboneID })
    let slide = try #require(trombone.geometry.first { $0.id == "slide" })

    let firstPosition = try #require(catalog.slidePitch(for: tromboneID, position: 1, harmonicPartial: 2))
    #expect(firstPosition.pitch == .init(.bFlat, octave: 2))
    #expect(firstPosition.namedPosition == "First")
    #expect(firstPosition.positionDeviation == 0)

    let seventhPosition = try #require(catalog.slidePitch(for: tromboneID, position: 7, harmonicPartial: 2))
    #expect(seventhPosition.pitch == .init(.e, octave: 2))
    #expect(seventhPosition.namedPosition == "Seventh")

    let thirdPartial = try #require(catalog.slidePitch(for: tromboneID, position: 1, harmonicPartial: 3))
    #expect(thirdPartial.pitch.pitchClass == .f)
    #expect(thirdPartial.pitch.octave == 3)
    #expect(thirdPartial.pitch.spelling.tuningOffsetCents == 2)

    let betweenPositions = try #require(catalog.slidePitch(for: tromboneID, position: 2.5, harmonicPartial: 2))
    #expect(betweenPositions.namedPosition == nil)
    #expect(betweenPositions.pitch.cents(relativeTo: .init(.bFlat, octave: 2)) == -150)

    let adjusted = try #require(catalog.slidePitch(for: tromboneID, position: 1, harmonicPartial: 2, adjustmentCents: -12))
    #expect(adjusted.pitch.cents(relativeTo: .init(.bFlat, octave: 2)) == -12)
    #expect(catalog.slidePitch(for: tromboneID, position: 7.1, harmonicPartial: 2) == nil)
    #expect(catalog.slidePitch(for: tromboneID, position: 1, harmonicPartial: 13) == nil)
    #expect(slide.properties["positionTolerance"] == .decimal(0.18))
    #expect(InstrumentCatalogValidator().validate(catalog).isEmpty)
}

@Test func harmonicaCombinesHoleBreathBendAndOverblowState() throws {
    let catalog = StandardInstruments.catalog
    let harmonica: InstrumentID = "instrument:harmonica:diatonic-10-hole:c"
    var state = InstrumentPerformanceState(modelID: harmonica)

    state.set(.integer(2), for: "hole")
    state.set(.text("blow"), for: "direction")
    #expect(catalog.resolve(state) == .pitch(.init(.e, octave: 4)))
    state.set(.text("draw"), for: "direction")
    #expect(catalog.resolve(state) == .pitch(.init(.g, octave: 4)))
    state.activeTechniques = ["bend"]
    state.set(.integer(-2), for: "bendSemitones")
    #expect(catalog.resolve(state) == .pitch(.init(.f, octave: 4)))
    state.set(.integer(3), for: "hole")
    state.set(.integer(-3), for: "bendSemitones")
    guard case .pitch(let tripleBend)? = catalog.resolve(state) else {
        Issue.record("Expected the authored triple-bend mapping")
        return
    }
    #expect(tripleBend.isAcousticallyEquivalent(to: .init(.aFlat, octave: 4)))
    state.activeTechniques = ["overblow"]
    state.set(.integer(6), for: "hole")
    state.set(.text("blow"), for: "direction")
    #expect(catalog.resolve(state) == .pitch(.init(.bFlat, octave: 5)))
    state.activeTechniques = ["overdraw"]
    state.set(.integer(7), for: "hole")
    state.set(.text("draw"), for: "direction")
    #expect(catalog.resolve(state) == .pitch(.init(.cSharp, octave: 6)))
    state.activeTechniques = ["bend"]
    state.set(.integer(5), for: "hole")
    state.set(.integer(-1), for: "bendSemitones")
    #expect(catalog.resolve(state) == nil)
}

@Test func accordionAndConcertinaResolveButtonPitchByBellowsDirection() throws {
    let catalog = StandardInstruments.catalog
    let accordion: InstrumentID = "instrument:accordion:piano"
    let concertina: InstrumentID = "instrument:concertina:anglo"

    var accordionState = InstrumentPerformanceState(modelID: accordion, values: ["button": .text("C#4"), "direction": .text("push")])
    #expect(catalog.resolve(accordionState) == .pitch(.init(.cSharp, octave: 4)))
    accordionState.set(.text("pull"), for: "direction")
    #expect(catalog.resolve(accordionState) == .pitch(.init(.cSharp, octave: 4)))

    var concertinaState = InstrumentPerformanceState(modelID: concertina, values: ["button": .text("C3"), "direction": .text("push")])
    #expect(catalog.resolve(concertinaState) == .pitch(.init(.c, octave: 4)))
    concertinaState.set(.text("pull"), for: "direction")
    #expect(catalog.resolve(concertinaState) == .pitch(.init(.d, octave: 4)))
    concertinaState.set(.text("G2"), for: "button")
    concertinaState.set(.text("push"), for: "direction")
    #expect(catalog.resolve(concertinaState) == .pitch(.init(.d, octave: 4)))
    concertinaState.set(.text("pull"), for: "direction")
    #expect(catalog.resolve(concertinaState) == .pitch(.init(.fSharp, octave: 4)))
    concertinaState.set(.text("missing"), for: "button")
    #expect(catalog.resolve(concertinaState) == nil)
}

@Test func timpaniRetuningChangesSubsequentlyPlayedPitchAndEnforcesDrumRange() throws {
    let catalog = StandardInstruments.catalog
    let timpani: InstrumentID = "instrument:percussion:timpani"
    var state = try #require(catalog.performanceState(for: timpani))
    state.set(.text("strike"), for: "interaction")
    state.set(.text("drum29"), for: "target")

    #expect(catalog.resolve(state) == .pitch(.init(.f, octave: 2)))
    let tunedToBFlat = state.set(.pitch(.init(.bFlat, octave: 2)), for: "drum29")
    #expect(tunedToBFlat)
    #expect(catalog.resolve(state) == .pitch(.init(.bFlat, octave: 2)))
    let tunedToB = state.set(.pitch(.init(.b, octave: 2)), for: "drum29")
    #expect(tunedToB)
    #expect(catalog.resolve(state) == .pitch(.init(.b, octave: 2)))
    let rejectedOutOfRangePitch = state.set(.pitch(.init(.d, octave: 3)), for: "drum29")
    #expect(!rejectedOutOfRangePitch)
    #expect(catalog.resolve(state) == .pitch(.init(.b, octave: 2)))
    state.set(.text("missing"), for: "target")
    #expect(catalog.resolve(state) == nil)
}

@Test func nyckelharpaFamilyPreservesModernAndHistoricalConstruction() throws {
    let catalog = StandardInstruments.catalog
    let chromatic = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:kromatisk" })
    let kontra = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:kontrabasharpa" })
    let silver = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:silverbasharpa" })
    let octave = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:oktavharpa" })
    let mora = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:moraharpa" })
    let esse = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:esseharpa" })
    let vefsen = try #require(catalog.models.first { $0.id.rawValue == "instrument:nyckelharpa:vefsenharpa" })
    let chromaticTuning = try #require(catalog.tunings.first { $0.id == chromatic.defaultTuning })
    let octaveTuning = try #require(catalog.tunings.first { $0.id == octave.defaultTuning })

    #expect(chromaticTuning.courses.map { $0.pitches[0].chromaticIndex } == [48, 55, 60, 69])
    #expect(octaveTuning.courses.map { $0.pitches[0].chromaticIndex } == [36, 43, 50, 57])
    #expect(kontra.geometry.first { $0.id == "keys" }?.properties["rows"] == .integer(1))
    #expect(silver.geometry.first { $0.id == "keys" }?.properties["rows"] == .integer(2))
    #expect(mora.geometry.first { $0.id == "sympatheticStrings" }?.properties["count"] == .integer(0))
    #expect(esse.geometry.first { $0.id == "tonalSystem" }?.properties["pureOctave"] == .boolean(true))
    #expect(vefsen.geometry.first { $0.id == "tonalSystem" }?.properties["pureOctave"] == .boolean(false))
    #expect(mora.tunings.isEmpty && esse.tunings.isEmpty && vefsen.tunings.isEmpty)
}

@Test func remainingStandardInstrumentDefinitionsAreAuthoredInTextualStdlib() throws {
    let source = TextSource(
        """
        module tests.complete-stdlib
        import tunings.guitar.dadgad
        import instruments.banjo
        import instruments.violin
        import instruments.cello
        import instruments.lute.renaissance
        import instruments.oud.arabic
        """,
        fileID: "complete-stdlib.utab"
    )
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let compiled = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))
    let expectedModels = [
        StandardInstruments.fiveStringBanjo,
        StandardInstruments.violin,
        StandardInstruments.cello,
        StandardInstruments.renaissanceLute,
        StandardInstruments.oud,
    ]
    let expectedTunings = [
        StandardInstruments.guitarDADGAD,
        StandardInstruments.banjoOpenG,
        StandardInstruments.violinStandard,
        StandardInstruments.celloStandard,
        StandardInstruments.renaissanceLuteG,
        StandardInstruments.arabicOud,
    ]

    #expect(loaded.succeeded)
    #expect(compiled.succeeded)
    for expected in expectedModels {
        #expect(compiled.catalog.models.first { $0.id == expected.id } == expected)
    }
    for expected in expectedTunings {
        #expect(compiled.catalog.tunings.first { $0.id == expected.id } == expected)
    }
    #expect(InstrumentCatalogValidator().validate(compiled.catalog).isEmpty)
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

@Test func hyphenatedLyricsPreserveWordsSyllablesAndStableIDs() {
    let first = LyricVerse("Twin-kle lit-tle star", id: "lyrics:verse-1", language: "en")
    let second = LyricVerse("Twin-kle lit-tle star", id: "lyrics:verse-1", language: "en")

    #expect(first.words.map(\.text) == ["Twinkle", "little", "star"])
    #expect(first.syllables.map(\.text) == ["Twin", "kle", "lit", "tle", "star"])
    #expect(first.syllables.map(\.position) == [.beginning, .end, .beginning, .end, .single])
    #expect(first == second)
}

@Test func lyricAlignmentBindsSyllablesToTimedNoteAttacks() {
    let melody = MusicalExpression.sequence([
        .note(.absolute(.init(.c, octave: 4)), duration: .quarter, id: "note:twin"),
        .rest(.quarter, id: "rest:between"),
        .note(.absolute(.init(.d, octave: 4)), duration: .half, id: "note:kle"),
    ])
    let lyrics = LyricVerse("Twin-kle", id: "lyrics:verse-1")
    let composition = Composition(
        title: "Lyrics",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init("verse", duration: .whole, parts: [
            .init(instrument: "voice", voices: [
                .init("melody", content: [.expression(melody)], lyrics: [lyrics]),
            ]),
        ])]
    )

    guard let named = NameResolutionStage().run(composition).output,
          let expanded = ReferenceExpansionStage().run(named).output,
          let timed = TemporalResolutionStage().run(expanded).output else {
        Issue.record("Expected temporal compilation to succeed")
        return
    }
    let aligned = LyricAlignmentStage().run(timed)
    let syllables = aligned.output?.sections.first?.parts.first?.voices.first?.lyrics.first?.syllables

    #expect(aligned.succeeded)
    #expect(syllables?.map(\.syllable.text) == ["Twin", "kle"])
    #expect(syllables?.map(\.offset) == [.zero, .half])
    #expect(syllables?.map(\.duration) == [.quarter, .half])
}

@Test func lyricAlignmentDiagnosesAttackCountMismatch() {
    let composition = Composition(
        title: "Broken Lyrics",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init("verse", duration: .whole, parts: [
            .init(instrument: "voice", voices: [
                .init(
                    "melody",
                    content: [.expression(.note(.absolute(.init(.c, octave: 4)), duration: .whole))],
                    lyrics: [.init("Twin-kle", id: "lyrics:verse-1")]
                ),
            ]),
        ])]
    )

    guard let named = NameResolutionStage().run(composition).output,
          let expanded = ReferenceExpansionStage().run(named).output,
          let timed = TemporalResolutionStage().run(expanded).output else {
        Issue.record("Expected temporal compilation to succeed")
        return
    }
    let result = LyricAlignmentStage().run(timed)

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("2 syllables") && $0.message.contains("1 lyric attacks") })
}

@Test func compilerLowersAlignedLyricsAsEventMetadata() throws {
    let composition = Composition(
        title: "Lowered Lyrics",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init("verse", duration: .whole, parts: [
            .init(instrument: "voice", voices: [
                .init(
                    "melody",
                    content: [.expression(.sequence([
                        .note(.absolute(.init(.c, octave: 4)), duration: .half, id: "note:twin"),
                        .note(.absolute(.init(.d, octave: 4)), duration: .half, id: "note:kle"),
                    ]))],
                    lyrics: [.init("Twin-kle", id: "lyrics:verse-1")]
                ),
            ]),
        ])]
    )
    let compiler = UTABCompositionCompiler(
        catalog: StandardInstruments.catalog,
        instrumentBindings: ["voice": testInstance("voice_i", model: StandardInstruments.voice.id)]
    )
    let result = compiler.compile(composition)
    let document = try #require(result.output)
    let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

    #expect(result.succeeded)
    #expect(json.contains("_lyrics"))
    #expect(json.contains("Twin"))
    #expect(json.contains("kle"))
}

@Test func textLexerRetainsSubstringSpellingAndPreciseHalfOpenRanges() throws {
    let source = TextSource("title \"Song\"\n  tempo 120.5\n", fileID: "score.utablang")
    let result = TextLexer().lex(source)
    let tempo = try #require(result.tokens.first { $0.lexeme == "120.5" })

    #expect(result.diagnostics.isEmpty)
    #expect(tempo.kind == .decimalLiteral)
    #expect(tempo.decimalValue == 120.5)
    #expect(tempo.range.fileID == "score.utablang")
    #expect(tempo.range.start == SourcePosition(line: 2, column: 9))
    #expect(tempo.range.end == SourcePosition(line: 2, column: 14))
}

@Test func textLexerRecognizesSignedNumericProperties() throws {
    let source = TextSource("actuator pitch { minimum -3.0; maximum +1 }", fileID: "signed.utablang")
    let result = TextLexer().lex(source)
    let minimum = try #require(result.tokens.first { $0.lexeme == "-3.0" })
    let maximum = try #require(result.tokens.first { $0.lexeme == "+1" })

    #expect(result.diagnostics.isEmpty)
    #expect(minimum.kind == .decimalLiteral)
    #expect(minimum.decimalValue == -3)
    #expect(maximum.kind == .integerLiteral)
    #expect(maximum.integerValue == 1)
}

@Test func textParserMakesProgressAfterMalformedProperty() {
    let result = TextParser().parse(.init("profile Broken { actuator keys { minimum @ } }"))

    #expect(!result.succeeded)
    #expect(result.diagnostics.count <= 3)
}

@Test func textParserAcceptsMultilineScaleClosingBrace() throws {
    let result = TextParser().parse(.init("""
        scale Unequal {
            cents 0, 76, 193
        }
        """))

    #expect(result.succeeded)
    #expect(try #require(result.syntax).scaleDefinitions.count == 1)
}

@Test func textParserReportsFileLineAndColumnForInvalidInput() {
    let result = TextParser().parse(.init("meter 4/4\n  @", fileID: "broken.utablang"))
    let diagnostic = result.diagnostics.first { $0.severity == .error }

    #expect(!result.succeeded)
    #expect(diagnostic?.range.fileID == "broken.utablang")
    #expect(diagnostic?.range.start == SourcePosition(line: 2, column: 3))
    #expect(diagnostic?.description.contains("broken.utablang:2:3") == true)
}

@Test func textualFrontendLowersInitialLanguageSliceIntoSemanticPipeline() throws {
    let source = TextSource(
        """
        title "Twinkle Text"
        meter 4/4
        tempo 100
        scale C major

        phrase melody {
            C4 h
            D4 h
        }

        section verse : 1 bars {
            voice {
                voice melody {
                    lyrics { "Twin-kle" }
                    melody
                }
            }
        }

        main { verse }
        """,
        fileID: "twinkle.utablang"
    )
    let frontend = TextCompositionFrontend().compile(source)
    let composition = try #require(frontend.composition)
    let compiler = UTABCompositionCompiler(
        catalog: StandardInstruments.catalog,
        instrumentBindings: ["voice": testInstance("voice_i", model: StandardInstruments.voice.id)]
    )
    let result = compiler.compile(composition)

    #expect(frontend.succeeded)
    #expect(composition.title == "Twinkle Text")
    #expect(composition.annotations.source?.fileID == "twinkle.utablang")
    #expect(composition.phrases.first?.annotations.source?.start.line == 6)
    #expect(result.succeeded)
}

@Test func sectionHarmonyLowersIndependentlyOfInstrumentTracks() throws {
    let source = TextSource(
        """
        title "Harmony Timeline"
        meter 4/4
        tempo 100

        section verse : 2 bars {
            harmony {
                chord C major w
                chord F major h
                chord G major h
            }
            piano {
                voice melody {
                    C4 w
                    E4 w
                }
            }
        }

        main { verse }
        """,
        fileID: "harmony.utab"
    )
    let frontend = TextCompositionFrontend().compile(source)
    let composition = try #require(frontend.composition)
    let harmony = try #require(composition.sections.first?.harmony)

    #expect(harmony.duration == MusicalDuration(2, 1))
    let realized = try #require(compileToRealized(
        composition,
        bindings: ["piano": testInstance("piano_i", model: StandardInstruments.piano.id)]
    ))
    let document = try #require(MinimalUTabLoweringStage().run(realized).output)
    let events = try #require(document.harmony)

    #expect(events.map(\.value.symbol) == ["C", "F", "G"])
    #expect(events.allSatisfy { $0.section == composition.sections[0].id.rawValue })
    #expect(events.allSatisfy { $0.source?["origin"] != nil })
    #expect(document.tracks.count == 1)
}

@Test func sectionHarmonyMustMatchExplicitSectionLength() throws {
    let composition = Composition(
        title: "Short harmony",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init(
            "verse",
            duration: .whole,
            harmony: .chord(.init(.c, .major), duration: .half),
            parts: []
        )]
    )
    let named = try #require(NameResolutionStage().run(composition).output)
    let expanded = try #require(ReferenceExpansionStage().run(named).output)
    let result = TemporalResolutionStage().run(expanded)

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains {
        $0.severity == .error && $0.path == "sections[0].harmony" && $0.message.contains("expected section duration")
    })
}

@Test func predominantlyDeviatingNotesProduceOneHarmonyHeuristicWarning() throws {
    let melody = MusicalExpression.sequence([
        .note(.absolute(.init(.cSharp, octave: 4)), duration: .quarter),
        .note(.absolute(.init(.d, octave: 4)), duration: .quarter),
        .note(.absolute(.init(.e, octave: 4)), duration: .quarter),
        .note(.absolute(.init(.f, octave: 4)), duration: .quarter),
    ])
    let composition = Composition(
        title: "Harmony warning",
        meter: .init(4, 4),
        tempo: 100,
        phrases: [],
        sections: [.init(
            "verse",
            duration: .whole,
            harmony: .chord(.init(.c, .major), duration: .whole),
            parts: [.init(instrument: "piano", voices: [.init("melody", content: [.expression(melody)])])]
        )]
    )
    let named = try #require(NameResolutionStage().run(composition).output)
    let expanded = try #require(ReferenceExpansionStage().run(named).output)
    let timed = try #require(TemporalResolutionStage().run(expanded).output)
    let result = PitchResolutionStage().run(timed)

    #expect(result.succeeded)
    let warnings = result.diagnostics.filter { $0.severity == .warning }
    #expect(warnings.count == 1)
    #expect(warnings[0].message.contains("1 of 4 note attacks"))
    #expect(warnings[0].message.contains("may be intentional"))
}

@Test func plainUTabSourceFileSelfValidatesExpectedDiagnostics() throws {
    let testFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LanguageFixtures/self-validation.utab")
    let text = try String(contentsOf: testFile, encoding: .utf8)
    let result = TextDiagnosticVerifier().verify(.init(text, fileID: testFile.lastPathComponent))

    #expect(UTabComposerLanguage.fileExtension == "utab")
    #expect(result.expectations.count == 2)
    #expect(result.succeeded)
}

@Test func diagnosticVerifierSupportsRelativeLocationsAndReportsUnexpectedDiagnostics() {
    let source = TextSource("// expected-warning@+1 {{careful}}\nitem\n", fileID: "verify.utab")
    let warning = TextDiagnostic(
        .warning,
        message: "be careful here",
        range: .init(fileID: "verify.utab", start: .init(line: 2, column: 1), end: .init(line: 2, column: 5))
    )
    let matched = TextDiagnosticVerifier().verify(source, diagnostics: [warning])
    let unexpected = TextDiagnosticVerifier().verify(source, diagnostics: [warning, .init(.error, message: "extra", range: warning.range)])

    #expect(matched.succeeded)
    #expect(unexpected.issues.contains { $0.kind == .unexpectedDiagnostic })
}

@Test func lexerInjectsLocatedSemicolonsAtEligibleNewlines() throws {
    let result = TextLexer().lex(.init("C4 q\nD4 q; E4 q\n", fileID: "timing.utab"))
    let semicolons = result.tokens.filter { $0.kind == .semicolon }

    #expect(semicolons.count == 2)
    #expect(semicolons[0].isSynthesized)
    #expect(semicolons[0].lexeme.isEmpty)
    #expect(semicolons[0].range.start == SourcePosition(line: 1, column: 5))
    #expect(!semicolons[1].isSynthesized)
    #expect(semicolons[1].lexeme == ";")
}

@Test func textualCommaIsParallelAndSemicolonOrNewlineIsSequential() throws {
    let source = TextSource(
        """
        meter 4/4
        tempo 100
        phrase harmony {
            C4 q, E4 q,
            G4 q
            C5 h
        }
        """,
        fileID: "temporal.utab"
    )
    let result = TextCompositionFrontend().compile(source)
    let phrase = try #require(result.composition?.phrases.first)
    guard case .sequence(let sequence) = phrase.expression.kind,
          case .parallel(let parallel) = sequence.first?.kind else {
        Issue.record("Expected a sequential phrase beginning with a parallel expression")
        return
    }

    #expect(result.succeeded)
    #expect(sequence.count == 2)
    #expect(parallel.count == 3)
    #expect(parallel.allSatisfy { $0.duration == .quarter })
    #expect(sequence[1].duration == .half)
}

@Test func textualParserDiagnosesMissingSequentialSeparator() {
    let result = TextParser().parse(.init("meter 4/4\ntempo 100\nphrase bad { C4 q D4 q }", fileID: "missing-semicolon.utab"))

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("Expected ';' or newline") })
}

@Test func completeTextualTwinkleCompilesDeterministicallyToUTab() throws {
    let testFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LanguageFixtures/twinkle.utab")
    let source = TextSource(try String(contentsOf: testFile, encoding: .utf8), fileID: testFile.lastPathComponent)
    let compiler = UTabTextCompiler()
    let first = compiler.compile(source, modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    let second = compiler.compile(source, modules: StandardTextModuleProvider())
    let firstDocument = try #require(first.document)
    let secondDocument = try #require(second.document)
    let composition = try #require(first.composition)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let firstData = try encoder.encode(firstDocument)
    let secondData = try encoder.encode(secondDocument)

    #expect(first.succeeded)
    #expect(second.succeeded)
    #expect(first.diagnostics.isEmpty)
    #expect(String(decoding: try #require(first.artifact(.midi)).data.prefix(4), as: UTF8.self) == "MThd")
    #expect(composition.phrases.first?.bars.count == 2)
    #expect(composition.phrases.first?.bars.first?.annotations.source?.fileID == "twinkle.utab")
    #expect(firstData == secondData)
    #expect(firstDocument.setup.instruments.map(\.id).sorted() == ["guitar_i", "guitar_ii", "piano_i", "voice_i"])
    #expect(stableFingerprint(firstData) == "51c350c1e7a920cb")
}

@Test func importedStandardLibraryModelsAndTuningExtensionsBuildCatalog() throws {
    let root = TextSource(
        """
        module examples.catalogue
        import instruments.guitar
        import tunings.guitar.drop
        import instruments.guitar.twelve-string
        instrument rhythm : Guitar as "Rhythm Guitar"
        meter 4/4
        tempo 100
        """,
        fileID: "catalogue.utab"
    )
    let loaded = TextModuleLoader().load(root: root, provider: StandardTextModuleProvider())
    let compiled = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))
    let semantic = try #require(loaded.root.map { TextSemanticLowerer().lower($0.syntax) })
    let resolved = TextInstrumentResolver().resolve(semantic.instruments, in: compiled.catalog, modelBindings: compiled.modelBindings)
    let guitar = try #require(compiled.catalog.models.first { $0.id.rawValue == "instrument:guitar:classical-six-string" })
    let twelveString = try #require(compiled.catalog.models.first { $0.id.rawValue == "instrument:guitar:twelve-string" })
    let doubledCourse = try #require(compiled.catalog.tunings.first { $0.id.rawValue == "tuning:guitar-12:standard" }?.courses.first)
    let bowedProfile = try #require(compiled.catalog.profiles.first { $0.id.rawValue == "profile:fretless-bowed-strings" })
    let bowedStrings = try #require(bowedProfile.actuators.first { $0.id == "strings" })

    #expect(loaded.succeeded)
    #expect(loaded.modules.map(\.name) == ["profiles.core", "instruments.guitar", "tunings.guitar.drop", "instruments.guitar.twelve-string", "examples.catalogue"])
    #expect(compiled.succeeded)
    #expect(compiled.catalog.profiles.count == 6)
    #expect(compiled.profileBindings["profiles.core.FrettedStrings"]?.rawValue == "profile:fretted-strings")
    #expect(guitar.profile.rawValue == "profile:fretted-strings")
    #expect(bowedStrings.cardinality == .range(1...16))
    #expect(bowedStrings.control == .continuous(range: 0...1))
    #expect(bowedProfile.interactions.contains { $0.id == "bow" && $0.effectors == ["bow"] })
    #expect(bowedProfile.techniques.contains { $0.id == "pizzicato" && $0.target == "strings" })
    #expect(guitar.tunings.map(\.rawValue) == ["tuning:guitar:standard", "tuning:guitar:drop-d"])
    #expect(guitar.defaultTuning?.rawValue == "tuning:guitar:standard")
    #expect(twelveString.defaultTuning?.rawValue == "tuning:guitar-12:standard")
    #expect(doubledCourse.pitches.map(\.chromaticIndex) == [40, 52])
    #expect(resolved.bindings["rhythm"]?.model == guitar.id)
}

@Test func hurrianHymnFixtureCompilesWithReconstructedMelodyAndLyrics() throws {
    let testFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LanguageFixtures/hurrian-hymn-6.utab")
    let source = TextSource(try String(contentsOf: testFile, encoding: .utf8), fileID: testFile.lastPathComponent)
    let result = UTabTextCompiler().compile(source, modules: StandardTextModuleProvider())
    let composition = try #require(result.composition)
    let verse = try #require(composition.sections.first?.parts.first?.voices.first?.lyrics.first)

    #expect(result.succeeded)
    #expect(result.diagnostics.isEmpty)
    #expect(composition.phrases.first?.bars.count == 9)
    #expect(verse.syllables.count == 34)
    #expect(result.document?.setup.instruments.first?.id == "sammu")
}

@Test func catalogueLookupUsesSwiftLikeImportedAndQualifiedNames() throws {
    let provider = DictionaryTextModuleProvider([
        "catalogue.a": .init(
            """
            module catalogue.a
            profile Strings { id "profile:a" }
            model Guitar : Strings { id "instrument:a" }
            """,
            fileID: "a.utab"
        ),
        "catalogue.b": .init(
            """
            module catalogue.b
            profile Strings { id "profile:b" }
            model Guitar : Strings { id "instrument:b" }
            """,
            fileID: "b.utab"
        ),
    ])
    let qualified = TextModuleLoader().load(
        root: .init(
            """
            module example
            import catalogue.a
            import catalogue.b
            instrument first : catalogue.a.Guitar
            instrument second : catalogue.b.Guitar
            extension catalogue.a.Guitar {
                tuning Alternate { id "tuning:a:alternate"; course E2 }
            }
            """,
            fileID: "qualified.utab"
        ),
        provider: provider
    )
    let compiled = TextInstrumentCatalogCompiler().compile(qualified.modules, extending: .init(profiles: [], models: []))
    let semantic = try #require(qualified.root.map { TextSemanticLowerer().lower($0.syntax) })
    let resolved = TextInstrumentResolver().resolve(semantic.instruments, in: compiled.catalog, modelBindings: compiled.modelBindings)

    #expect(compiled.succeeded)
    #expect(resolved.bindings["first"]?.model.rawValue == "instrument:a")
    #expect(resolved.bindings["second"]?.model.rawValue == "instrument:b")
    #expect(compiled.catalog.models.first { $0.id.rawValue == "instrument:a" }?.tunings.first?.rawValue == "tuning:a:alternate")
    #expect(compiled.modelBindings["Guitar"] == nil)
}

@Test func catalogueLookupDiagnosesAmbiguousImportedNames() {
    let provider = DictionaryTextModuleProvider([
        "catalogue.a": .init("module catalogue.a\nprofile P { id \"profile:a\" }\nmodel Guitar : P { id \"instrument:a\" }", fileID: "a.utab"),
        "catalogue.b": .init("module catalogue.b\nprofile P { id \"profile:b\" }\nmodel Guitar : P { id \"instrument:b\" }", fileID: "b.utab"),
    ])
    let loaded = TextModuleLoader().load(
        root: .init("module example\nimport catalogue.a\nimport catalogue.b\ninstrument guitar : Guitar", fileID: "ambiguous.utab"),
        provider: provider
    )
    let compiled = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))

    #expect(!compiled.succeeded)
    #expect(compiled.diagnostics.contains {
        $0.range.fileID == "ambiguous.utab"
            && $0.message.contains("catalogue.a.Guitar")
            && $0.message.contains("catalogue.b.Guitar")
    })
    #expect(compiled.modelBindings["Guitar"] == nil)
    #expect(compiled.modelBindings["catalogue.a.Guitar"]?.rawValue == "instrument:a")
    #expect(compiled.modelBindings["catalogue.b.Guitar"]?.rawValue == "instrument:b")
}

@Test func moduleLoaderDiagnosesImportCyclesAtImportLocation() {
    let provider = DictionaryTextModuleProvider([
        "cycle.a": .init("module cycle.a\nimport cycle.b\n", fileID: "a.utab"),
        "cycle.b": .init("module cycle.b\nimport cycle.a\n", fileID: "b.utab"),
    ])
    let result = TextModuleLoader().load(
        root: .init("module root\nimport cycle.a\n", fileID: "root.utab"),
        provider: provider
    )

    #expect(!result.succeeded)
    #expect(result.diagnostics.contains {
        $0.range.fileID == "b.utab" && $0.message.contains("cycle.a -> cycle.b -> cycle.a")
    })
}

@Test func textualProfilesDiagnoseInvalidControlsAndCapabilityTargets() {
    let loaded = TextModuleLoader().load(
        root: .init(
            """
            module profiles.invalid
            profile Broken {
                actuator switches { control orderedBitset }
                interaction play { targets strings }
                technique bend { target strings }
            }
            """,
            fileID: "invalid-profile.utab"
        ),
        provider: DictionaryTextModuleProvider([:])
    )
    let compiled = TextInstrumentCatalogCompiler().compile(
        loaded.modules,
        extending: .init(profiles: [], models: [])
    )

    #expect(!compiled.succeeded)
    #expect(compiled.diagnostics.contains { $0.message.contains("requires a positive width") })
    #expect(compiled.diagnostics.contains { $0.message.contains("targets unknown actuator group 'strings'") })
}

@Test func textCompilerDriverProducesUTabJSONAndMIDIFromImportedSource() throws {
    let source = TextSource(
        """
        module examples.single-note
        import instruments.guitar

        title "Compiler Driver"
        instrument guitar_i : Guitar as "Guitar"
        meter 4/4
        tempo 96

        section verse : 1 bars {
            guitar_i {
                voice melody {
                    E2 w
                }
            }
        }
        main { verse }
        """,
        fileID: "compiler-driver.utab"
    )
    let result = UTabTextCompiler().compile(
        source,
        modules: StandardTextModuleProvider(),
        options: .init(outputs: [.uTabJSON, .midi], prettyPrintedJSON: false)
    )
    let document = try #require(result.document)
    let json = try #require(result.artifact(.uTabJSON))
    let midi = try #require(result.artifact(.midi))
    let decoded = try JSONDecoder().decode(UTabDocument.self, from: json.data)

    #expect(result.succeeded)
    #expect(result.modules.map(\.name) == ["profiles.core", "instruments.guitar", "examples.single-note"])
    #expect(result.instrumentBindings["guitar_i"]?.model.rawValue == "instrument:guitar:classical-six-string")
    #expect(decoded.utab.documentId == document.utab.documentId)
    #expect(json.suggestedFileExtension == "utab.json")
    #expect(midi.suggestedFileExtension == "mid")
    #expect(String(decoding: midi.data.prefix(4), as: UTF8.self) == "MThd")
}

@Test func filesystemModuleProviderSupportsNestedFlatAndLayeredLookup() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nested = temporary.appendingPathComponent("instruments", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    try "module instruments.local\n".write(
        to: nested.appendingPathComponent("local.utab"),
        atomically: true,
        encoding: .utf8
    )
    try "module tunings.local\n".write(
        to: temporary.appendingPathComponent("tunings.local.utab"),
        atomically: true,
        encoding: .utf8
    )
    let filesystem = FileSystemTextModuleProvider(searchRoots: [temporary])
    let layered = LayeredTextModuleProvider([
        DictionaryTextModuleProvider(["instruments.local": .init("module override\n", fileID: "override.utab")]),
        filesystem,
    ])

    #expect(filesystem.source(for: "instruments.local")?.fileID.hasSuffix("instruments/local.utab") == true)
    #expect(filesystem.source(for: "tunings.local")?.fileID.hasSuffix("tunings.local.utab") == true)
    #expect(layered.source(for: "instruments.local")?.fileID == "override.utab")
}
