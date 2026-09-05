import Testing
import UTABComposerCore
import UTABComposerText
import UTABInstrumentLibrary
import UTABLowering

private func semantic(_ body: String, provider: any TextModuleProvider = StandardTextModuleProvider()) throws -> Composition {
    let loaded = TextModuleLoader().load(root: TextSource(body, fileID: "duration-naming.utab"), provider: provider)
    #expect(loaded.diagnostics.isEmpty, "\(loaded.diagnostics)")
    let result = TextSemanticLowerer().lower(loaded.modules)
    #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    return try #require(result.composition)
}

private func timed(_ body: String, provider: any TextModuleProvider = StandardTextModuleProvider()) throws -> [TimedExpression] {
    let composition = try semantic(body, provider: provider)
    let names = NameResolutionStage().run(composition)
    #expect(names.diagnostics.isEmpty, "\(names.diagnostics)")
    let expansion = ReferenceExpansionStage().run(try #require(names.output))
    #expect(expansion.diagnostics.isEmpty, "\(expansion.diagnostics)")
    let timing = TemporalResolutionStage().run(try #require(expansion.output))
    #expect(timing.diagnostics.isEmpty, "\(timing.diagnostics)")
    return try #require(timing.output).sections.flatMap(\.parts).flatMap(\.voices).flatMap { leaves($0.expression) }
}

private func leaves(_ expression: TimedExpression) -> [TimedExpression] {
    switch expression.kind {
    case .sequence(let children), .parallel(let children): children.flatMap(leaves)
    case .technique(let application): application.operands.flatMap(leaves)
    default: [expression]
    }
}

private func containsTechnique(_ name: String, in expression: MusicalExpression) -> Bool {
    switch expression.kind {
    case .sequence(let children), .parallel(let children):
        children.contains { containsTechnique(name, in: $0) }
    case .repeated(_, let child), .proportional(_, let child), .barAssertion(let child):
        containsTechnique(name, in: child)
    case .technique(let application):
        application.technique == name || application.operands.contains { containsTechnique(name, in: $0) }
    default: false
    }
}

private func absolutePitches(_ expressions: [TimedExpression]) -> [AbsolutePitch] {
    expressions.compactMap { expression in
        if case .note(.absolute(let pitch), _) = expression.kind { return pitch }
        return nil
    }
}

@Test func dottedAndFractionalDurationsUseExactWholeNotes() throws {
    let events = try timed("""
        meter 4/4
        tempo 120
        section test { piano { voice melody {
            C4 q.
            D4 q..
            rest [6/16]
            chord E minor [1/32]
            @3[0] [5/12]
            pluck strings[1] e.
        } } }
        """)
    #expect(events.map(\.duration) == [MusicalDuration(3,8), MusicalDuration(7,16), MusicalDuration(3,8), MusicalDuration(1,32), MusicalDuration(5,12), MusicalDuration(3,16)])
    #expect(events[1].offset == MusicalDuration(3,8))
}

@Test func nestedTupletsAndOccurrenceStretchingPreserveTimingAndReuse() throws {
    let events = try timed("""
        meter 4/4
        tempo 120
        phrase motif { C4 e; D4 e }
        section test { piano { voice melody {
            tuplet 3:2 {
                C4 e
                tuplet 5:4 { D4 s; E4 s; F4 s; G4 s; A4 s }
                B4 e
            }
            stretch 3/2 { motif }
            motif
            stretch 1/2 { repeat 2 { C4 q, E4 e } }
        } } }
        """)
    #expect(events.prefix(7).map(\.duration) == [MusicalDuration(1,12)] + Array(repeating: MusicalDuration(1,30), count: 5) + [MusicalDuration(1,12)])
    #expect(events[7].offset == MusicalDuration(1,3))
    #expect(events[7].duration == MusicalDuration(3,16))
    #expect(events[9].duration == .eighth)
    #expect(events[11].offset == events[12].offset)
    #expect(events[13].offset == events[11].offset + MusicalDuration(1,8))
    #expect(events[1].provenance.expansionPath.contains { $0.contains("proportional") })
}

@Test func scaledBarsCheckEffectiveDuration() throws {
    let composition = try semantic("""
        meter 4/4
        tempo 100
        phrase full { bar { C4 w } }
        section test { piano { voice melody { stretch 1/2 { full } } } }
        """)
    let result = ReferenceExpansionStage().run(try #require(NameResolutionStage().run(composition).output))
    #expect(result.output == nil)
    #expect(result.diagnostics.contains { $0.message.contains("Bar duration is 1/2; expected 1/1") && $0.range != nil })
    let events = try timed("""
        meter 4/4
        tempo 100
        section test { piano { voice melody {
            bar { repeat 4 { tuplet 3:2 { C4 e; D4 e; E4 e } } }
        } } }
        """)
    #expect(events.last!.offset + events.last!.duration == .whole)
}

@Test func durationErrorsAreDiagnosedWithoutPlayableOutput() {
    for duration in ["[0/4]", "[1/0]", "[-1/4]", "[1/-4]", "[999999999999999999999999/4]", "q" + String(repeating: ".", count: 80), "[1/4].", "q .", "[1 4]"] {
        let parsed = TextParser().parse(TextSource("meter 4/4; tempo 100; phrase a { C4 \(duration) }"))
        if let syntax = parsed.syntax {
            #expect(!TextSemanticLowerer().lower(syntax).succeeded, "\(duration)")
        } else { #expect(!parsed.diagnostics.isEmpty) }
    }
}

@Test func proportionalOverflowFailsWithSourceDiagnostic() throws {
    for body in ["stretch 9223372036854775807/1 { C4 h; D4 h; E4 h }", "stretch 9223372036854775807/1 { stretch 2/1 { C4 q } }"] {
        let composition = try semantic("meter 4/4; tempo 100; section s { piano { voice v { \(body) } } }")
        let result = ReferenceExpansionStage().run(try #require(NameResolutionStage().run(composition).output))
        #expect(result.output == nil)
        #expect(result.diagnostics.contains { $0.message.contains("overflow") && $0.range != nil }, "\(result.diagnostics)")
    }
}

@Test func scopedGermanNamingDoesNotReinterpretReusedPhrases() throws {
    let events = try timed("""
        import std.naming.western.german
        import std.naming.western.english
        meter 4/4
        tempo 100
        phrase english { B4 q }
        phrase german {
            using notation German
            H4 q
            B4 q
            repeat 1 {
                using notation English
                B4 q
            }
            B4 q
        }
        section s { piano { voice v {
            using notation German
            english
            german
            Fis[4] q
            H#4 q
        } } }
        """)
    let pitches = absolutePitches(events)
    #expect(pitches.map { $0.spelling.accidental } == [0, 0, -1, 0, -1, 1, 1])
    #expect(pitches[5].spelling.letter == .f)
    #expect(events[2].annotations.metadata["namingSystem"] == .string("std.naming.western.german.German"))
}

@Test func relativeAndFixedNamingTablesCoexistWithoutImportEffects() throws {
    let events = try timed("""
        import std.naming.solfege.fixed
        import std.naming.solfege.movable
        import std.naming.arabic.degrees
        meter 4/4
        tempo 100
        section s { piano { voice v {
            using notation FixedSolfege
            do[4] q
            repeat 1 { using notation MovableSolfege; do[0] q; mi#[0] q }
            repeat 1 { using notation ArabicDegrees; sikah[0] q }
            @3[0] q
        } } }
        """)
    #expect(absolutePitches(events).first?.spelling.letter == .c)
    if case .note(.scaleDegree(let degree, let octave, let alteration), _) = events[2].kind {
        #expect(degree == 3 && octave == 0 && alteration == 1)
    } else { Issue.record("Expected a relative named pitch") }
    if case .note(let named, _) = events[3].kind, case .note(let direct, _) = events[4].kind { #expect(named == direct) }
}

@Test func notationDiagnosticsCoverUnknownLateDuplicateAndAmbiguousSelections() {
    for body in ["using notation German", "phrase a { using notation German; using notation German; H4 q }", "phrase a { using notation Missing }", "phrase a { using notation German; Z4 q }", "phrase a { H4 q }"] {
        let loaded = TextModuleLoader().load(root: TextSource("import std.naming.western.german; meter 4/4; tempo 100; \(body)"), provider: StandardTextModuleProvider())
        #expect(!loaded.succeeded || !TextSemanticLowerer().lower(loaded.modules).succeeded, "\(body)")
    }
}

@Test func usingDeclarationsApplyToTheirWholeEnclosingSequence() throws {
    let events = try timed("""
        import std.naming.western.german
        meter 4/4
        tempo 100
        section s { piano { voice v {
            bar {
                B4 q
                using notation German
                H4 q
                using legato
                C5 h
            }
        } } }
        """)
    #expect(absolutePitches(events).map { $0.spelling.accidental } == [-1, 0, 0])

    let composition = try semantic("""
        meter 4/4
        tempo 100
        section s { piano { voice v {
            bar { C4 q; using legato; D4 q; E4 q rearticulate; F4 q letRing }
        } } }
        """)
    guard case .expression(let voiceExpression) = composition.sections[0].parts[0].voices[0].content[0] else {
        Issue.record("Expected voice expression")
        return
    }
    #expect(containsTechnique("legato", in: voiceExpression))
}

@Test func looseTechniqueBlocksAndModifiersReachPerformanceEvents() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            C4 q
            legato { D4 q; E4 q rearticulate }
            F4 q letRing
        } } }
        main { s }
        """, fileID: "articulation.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.map(\.techniques) == [nil, ["legato"], ["legato", "rearticulate"], ["letRing"]])
}

@Test func letRingExtendsPerformanceUntilDampButPreservesWrittenDuration() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            C4 q letRing
            D4 q
            damp
            rest h
        } } }
        main { s }
        """, fileID: "ringing.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    let attacks = events.filter { $0.action == "press" }
    #expect(attacks.map { $0.duration?.quarterNotes } == [.string("2/1"), .string("1/1")])
    #expect(events.contains { $0.action == "damp" && $0.at.musical?.beat == 3 })
    let occurrences = try #require(result.document?.editingMap?.occurrences)
    #expect(occurrences.first?.duration.quarterNotes == .string("1/1"))
}

@Test func importedPhraseNamesBindAtDeclarationSite() throws {
    let provider = DictionaryTextModuleProvider([
        "names": TextSource("module names; naming German { register absoluteOctave; note H = letter(B, 0); note B = letter(B, -1) }", fileID: "names.utab"),
        "library": TextSource("module library; import names; phrase figure { using notation German; B4 q }", fileID: "library.utab")
    ])
    let events = try timed("""
        import library
        meter 4/4
        tempo 100
        phrase figure { B4 q }
        section s { piano { voice v { library.figure; figure } } }
        """, provider: provider)
    #expect(absolutePitches(events).map { $0.spelling.accidental } == [-1, 0])
}

@Test func namingAppliesToCompositionTonicsConstantsAndNestedBodies() throws {
    let composition = try semantic("""
        import std.naming.western.german
        import std.naming.western.english
        composition {
            using notation German
            meter 4/4
            tempo 100
            scale H major
            let root = B
            phrase motif { root[4] q }
            section s {
                using notation English
                piano { voice v { motif; B4 q } }
            }
        }
        """)
    #expect(composition.scale?.tonic == .b)
    let names = try #require(NameResolutionStage().run(composition).output)
    let expanded = try #require(ReferenceExpansionStage().run(names).output)
    let timed = try #require(TemporalResolutionStage().run(expanded).output)
    let events = timed.sections.flatMap(\.parts).flatMap(\.voices).flatMap { leaves($0.expression) }
    #expect(absolutePitches(events).map { $0.spelling.accidental } == [-1, 0])
}

@Test func namingTablesRejectMixedTargetsAndAmbiguousImports() {
    let provider = DictionaryTextModuleProvider([
        "one": TextSource("module one; naming Names { register absoluteOctave; note X = letter(C, 0) }", fileID: "one.utab"),
        "two": TextSource("module two; naming Names { register absoluteOctave; note X = letter(D, 0) }", fileID: "two.utab")
    ])
    for imports in ["import one; import two", "import two; import one"] {
        let loaded = TextModuleLoader().load(root: TextSource("\(imports); meter 4/4; tempo 100; phrase p { using notation Names; X4 q }"), provider: provider)
        let result = TextSemanticLowerer().lower(loaded.modules)
        #expect(result.diagnostics.contains { $0.message.contains("Ambiguous naming system") })
    }
    for entries in ["note x = degree(1, 0)", "note x = letter(C, 0); note x = letter(D, 0)", "note x = letter(Z, 0)", "note x = letter(C, -9223372036854775808)"] {
        let parsed = TextParser().parse(TextSource("naming Invalid { register absoluteOctave; \(entries) }; meter 4/4; tempo 100"))
        if let syntax = parsed.syntax { #expect(!TextSemanticLowerer().lower(syntax).succeeded) }
        else { #expect(!parsed.diagnostics.isEmpty) }
    }
}

@Test func performanceSubdivisionsScaleWithTheirChordOccurrences() throws {
    for subdivision in ["e.", "[3/16]"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.guitar
            meter 4/4
            tempo 100
            instrument guitar : Guitar
            performancePattern pattern { subdivision \(subdivision); steps { strum down } }
            section s { guitar { voice v {
                stretch 2/1 { perform pattern { chord G major q. using cowboyG } }
            } } }
            main { s }
            """), modules: StandardTextModuleProvider())
        #expect(result.succeeded, "\(result.diagnostics)")
        let strums = try #require(result.document?.tracks.first?.parts?.first?.events).filter { $0.action == "strum" }
        #expect(strums.count == 2)
    }
}

@Test func rationalArithmeticReducesBeforeNarrowingAndFractionsAllowWhitespace() throws {
    let max = Int.max
    #expect(Rational(max, max - 1).adding(Rational(max, max - 1)) == Rational(max, (max - 1) / 2))
    #expect(Rational(max, 2).multiplied(by: Rational(2, max)) == Rational(1))
    #expect(Rational(max, max - 1) > Rational(max - 1, max))
    let events = try timed("""
        meter 4/4
        tempo 100
        section s { piano { voice v {
            C[4] [
                5 /
                12
            ]
        } } }
        """)
    #expect(events.first?.duration == MusicalDuration(5,12))
}

@Test func legacyNamingModulePathsRequireExplicitSelection() throws {
    for (module, system, name) in [("std.solfege.fixed", "FixedSolfege", "do[4]"), ("std.solfege.movable", "MovableSolfege", "do[0]"), ("std.notes.oud.arabic", "ArabicDegrees", "sikah[0]")] {
        _ = try semantic("import \(module); meter 4/4; tempo 100; phrase p { using notation \(system); \(name) q }")
        let loaded = TextModuleLoader().load(root: TextSource("import \(module); meter 4/4; tempo 100; phrase p { \(name) q }"), provider: StandardTextModuleProvider())
        #expect(!TextSemanticLowerer().lower(loaded.modules).succeeded)
    }
}

@Test func tuningCoursesResolveScopedNamingThroughTheCatalog() throws {
    let source = TextSource("""
        import instruments.guitar
        import std.naming.western.german
        extension Guitar {
            tuning germanExample {
                using notation German
                course E2
                course A2
                course D3
                course G3
                course H3
                course E4
            }
        }
        meter 4/4
        tempo 100
        """)
    let loaded = TextModuleLoader().load(root: source, provider: StandardTextModuleProvider())
    let result = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: .init(profiles: [], models: []))
    #expect(result.succeeded, "\(result.diagnostics)")
    let tuning = try #require(result.catalog.tunings.first { $0.name == "germanExample" })
    #expect(tuning.courses[4].pitches.first?.spelling.letter == .b)
    #expect(tuning.courses[4].pitches.first?.spelling.accidental == 0)
}

@Test func backendRejectsUnrepresentableTimingWithoutTrapping() {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.guitar
        meter 4/4
        tempo 100
        instrument guitar : Guitar
        section s { guitar { voice v { E4 [9223372036854775807/1] } } }
        main { s }
        """), modules: StandardTextModuleProvider())
    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("supported rational range") })
}

@Test func tiesAcrossBarsProduceOneSustainedAttackAndPreserveSegments() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s : 2 bars { piano { voice v {
            bar { C4 h; rest q; C4 q~ }
            bar { C4 q; rest h. }
        } } }
        main { s }
        """, fileID: "ties.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.filter { $0.action == "press" }.count == 2)
    #expect(events.last?.duration?.quarterNotes == .string("2/1"))
    let occurrences = try #require(result.document?.editingMap?.occurrences)
    #expect(occurrences.count == 5)
}

@Test func dynamicsAreScopeWideLocallyOverridableAndAccented() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            bar {
                C4 q
                dynamics p { D4 q; E4 q accent }
                F4 q
                using dynamics mf
            }
        } } }
        main { s }
        """, fileID: "dynamics.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events.filter { $0.action == "press" })
    #expect(events.count == 4)
    #expect(events[0].parameters?["intensity"] == .number(0.66))
    #expect(events[1].parameters?["intensity"] == .number(0.38))
    #expect(events[2].parameters?["intensity"] == .number(0.48))
    #expect(events[2].parameters?["accent"] == .boolean(true))
    #expect(events[2].techniques?.contains("accent") == true)
    #expect(events[3].parameters?["intensity"] == .number(0.66))
    #expect(events.allSatisfy { !($0.techniques ?? []).contains(where: { $0.hasPrefix("__dynamic") }) })
}

@Test func dynamicsRejectUnknownLevelsAndDuplicateScopePolicies() {
    for body in ["using dynamics loud; C4 w", "using dynamics p; using dynamics f; C4 w", "dynamics nope { C4 w }"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { bar { \(body) } } } }
            main { s }
            """, fileID: "invalid-dynamics.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded)
        #expect(result.diagnostics.contains { $0.message.contains("dynamic") || $0.message.contains("Dynamic") })
    }
}

@Test func dynamicEnvelopesInterpolateAtScorePosition() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v { bar {
            dynamics p { crescendo to f {
                C4 q; D4 q; E4 q; F4 q
            } }
        } } } }
        main { s }
        """, fileID: "envelope-pedal.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    let notes = events.filter { $0.action == "press" }
    #expect(notes.map { $0.parameters?["intensity"] } == [.number(0.38), .number(0.48), .number(0.58), .number(0.68)])
}

@Test func nestedPedalScopesEmitOneBalancedStatePair() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v { bar {
            pedal { C4 q; pedal { D4 q }; E4 q; F4 q }
        } } } }
        main { s }
        """, fileID: "pedal.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.filter { $0.action == "pedalDown" }.count == 1)
    #expect(events.filter { $0.action == "pedalUp" }.count == 1)
}

@Test func dynamicEnvelopeDirectionMustAgreeWithItsTarget() {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v { bar {
            dynamics f { crescendo to p { C4 w } }
        } } } }
        main { s }
        """, fileID: "invalid-envelope.utab"), modules: StandardTextModuleProvider())
    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("crescendo target must be louder") })
}

@Test func invalidTiesProduceSourceDiagnostics() {
    for notes in ["C4 q~; D4 q; rest h", "C4 q; D4 q; E4 q; F4 q~"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(notes) } } }
            main { s }
            """, fileID: "invalid-tie.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded)
        #expect(result.diagnostics.contains { $0.message.contains("tie") || $0.message.contains("Tied") })
        #expect(result.diagnostics.contains { $0.range?.fileID == "invalid-tie.utab" })
    }
}

@Test func chordTiesSustainOnlySharedRealizedPitches() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            chord C major h~
            chord C sus4 h
        } } }
        main { s }
        """, fileID: "chord-ties.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    let attacks = events.filter { $0.action == "press" }
    #expect(attacks.count == 4)
    #expect(attacks.compactMap { $0.duration?.quarterNotes }.filter { $0 == .string("4/1") }.count == 2)
    #expect(attacks.compactMap { $0.duration?.quarterNotes }.filter { $0 == .string("2/1") }.count == 2)
    let occurrences = try #require(result.document?.editingMap?.occurrences)
    #expect(occurrences.filter { $0.kind == .actuator }.allSatisfy { $0.duration.quarterNotes == .string("2/1") })
}

@Test func chordTiesRequireAtLeastOneSharedRealizedPitch() {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            chord C major h~
            chord F# major h
        } } }
        main { s }
        """, fileID: "invalid-chord-tie.utab"), modules: StandardTextModuleProvider())
    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.message.contains("share at least one sounding pitch") })
}

@Test func tiesAcrossSectionOccurrencesUseEntrySpecificPlayback() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section a { piano { voice v { rest h; C4 h~ } } }
        section b { piano { voice v { C4 h; D4 h } } }
        main { a; b }
        """, fileID: "section-ties.utab"), modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    #expect(result.succeeded, "\(result.diagnostics)")
    let arrangement = try #require(result.document?.setup.arrangement)
    let parts = try #require(result.document?.tracks.flatMap { $0.parts ?? [] })
    let sourceOverride = try #require(parts.first { $0.entry == arrangement[0].id })
    let destinationOverride = try #require(parts.first { $0.entry == arrangement[1].id })
    #expect(sourceOverride.mode == .replace)
    #expect(sourceOverride.events.first { $0.action == "press" }?.duration?.quarterNotes == .string("4/1"))
    #expect(destinationOverride.events.filter { $0.action == "press" }.count == 1)
    #expect(destinationOverride.events.first { $0.action == "press" }?.at.musical?.beat == 3)
}

@Test func sectionBoundaryTiesValidateEveryActualArrangementOccurrence() {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section a { piano { voice v { rest h; C4 h~ } } }
        section b { piano { voice v { C4 w } } }
        section c { piano { voice v { D4 w } } }
        main { a; b; a; c }
        """, fileID: "invalid-section-tie.utab"), modules: StandardTextModuleProvider())
    #expect(!result.succeeded)
    #expect(result.diagnostics.contains { $0.path == "main[2]" && $0.message.contains("same sounding pitch") })
}

@Test func pickupAndFinalBarsPreserveTimelineAndCrossBoundaryTies() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s : 2 bars { piano { voice v {
            pickup { C4 q~ }
            bar { C4 q; D4 h. }
            final { E4 h. }
        } } }
        main { s }
        """, fileID: "pickup.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.filter { $0.action == "press" }.count == 3)
    #expect(events.first?.duration?.quarterNotes == .string("2/1"))
    #expect(events.last?.at.musical?.measure == 2)
}

@Test func partialBarsRequireBoundaryPlacementAndComplementaryDurations() {
    for music in [
        "bar { C4 w }; pickup { C4 q }",
        "final { C4 q }; bar { C4 w }",
        "pickup { C4 q }; final { C4 q }",
        "pickup { C4 w }",
    ] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(music) } } }
            main { s }
            """, fileID: "partial-bar-error.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded, "\(music)")
        #expect(result.diagnostics.contains { $0.range?.fileID == "partial-bar-error.utab" }, "\(result.diagnostics)")
    }
}

@Test func inlineMeterChangesControlFollowingBarsAndPartialFinals() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            bar { C4 w }
            meter 3/4
            bar { D4 h; E4 q }
            final { F4 q }
        } } }
        main { s }
        """, fileID: "meter-change.utab"), modules: StandardTextModuleProvider())
    #expect(result.succeeded, "\(result.diagnostics)")
    let section = try #require(result.document?.setup.sections?.first)
    #expect(section.length.measures == 3)
    #expect(section.meterMap?.map(\.numerator) == [4, 3])
    #expect(section.meterMap?.map { $0.at?["measure"] } == [.number(1), .number(2)])
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.last?.at.musical?.measure == 3)
    #expect(events.last?.at.musical?.beat == 1)
}

@Test func inlineMeterChangesRequireBoundariesAndValidateTheNewMeter() {
    for body in [
        "C4 q; meter 3/4; D4 h; E4 w",
        "bar { C4 w }; meter 3/4; final { D4 w }",
    ] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(body) } } }
            main { s }
            """, fileID: "invalid-meter-change.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded, "\(body)")
    }
}

@Test func inlineTempoChangesUseSequencePositionAndExplicitBeatUnits() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s : 2 bars { piano { voice v {
            C4 h
            tempo 90
            D4 h
            tempo q. = 80
            E4 w
        } } }
        main { s }
        """, fileID: "tempo-map.utab"), modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    #expect(result.succeeded, "\(result.diagnostics)")
    let map = try #require(result.document?.setup.time?.tempoMap)
    #expect(map.map(\.quarterNotesPerMinute) == [90, 120])
    #expect(map[0].at?["measure"] == .number(1))
    #expect(map[0].at?["beat"] == .number(3))
    #expect(map[1].at?["measure"] == .number(2))
    let midi = try #require(result.artifact(.midi)?.data)
    let bytes = [UInt8](midi)
    #expect((0..<(bytes.count - 2)).filter { Array(bytes[$0...($0 + 2)]) == [0xFF, 0x51, 0x03] }.count == 3)
}

@Test func inlineTempoRejectsInvalidAndConflictingChanges() {
    let invalid = TextParser().parse(TextSource("meter 4/4; tempo 100; phrase p { C4 q; tempo -2; D4 h. }", fileID: "invalid-tempo.utab"))
    #expect(invalid.syntax.map { !TextSemanticLowerer().lower($0).succeeded } == true)

    let conflict = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano {
            voice upper { tempo 90; C4 w }
            voice lower { tempo 110; C3 w }
        } }
        main { s }
        """, fileID: "conflicting-tempo.utab"), modules: StandardTextModuleProvider())
    #expect(!conflict.succeeded)
    #expect(conflict.diagnostics.contains { $0.message.contains("Conflicting tempo") })
}

@Test func tempoRampsResolveToDeterministicUTabAndMIDIMaps() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s : 2 bars { piano { voice v {
            tempo ramp to 140 over w steps 4
            C4 w
            D4 w
        } } }
        main { s }
        """, fileID: "tempo-ramp.utab"), modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    #expect(result.succeeded, "\(result.diagnostics)")
    let map = try #require(result.document?.setup.time?.tempoMap)
    #expect(map.map(\.quarterNotesPerMinute) == [110, 120, 130, 140])
    #expect(map.first?.at?["beat"] == .number(2))
    #expect(map.last?.at?["measure"] == .number(2))
    let bytes = [UInt8](try #require(result.artifact(.midi)?.data))
    #expect((0..<(bytes.count - 2)).filter { Array(bytes[$0...($0 + 2)]) == [0xFF, 0x51, 0x03] }.count == 5)
}

@Test func tempoRampsRejectInvalidResolutionAndSectionOverflow() {
    for directive in ["tempo ramp to 120 over w steps 0; C4 w", "tempo ramp to 120 over [2/1]; C4 w"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(directive) } } }
            main { s }
            """, fileID: "invalid-ramp.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded, "\(directive)")
    }
}

@Test func fermataStretchesPerformedTimeWithoutChangingScoreDuration() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            C4 h
            fermata q factor 2
            D4 q
            E4 q
        } } }
        main { s }
        """, fileID: "fermata.utab"), modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    #expect(result.succeeded, "\(result.diagnostics)")
    let map = try #require(result.document?.setup.time?.tempoMap)
    #expect(map.map(\.quarterNotesPerMinute) == [50, 100])
    #expect(map.map { $0.at?["beat"] } == [.number(3), .number(4)])
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.compactMap(\.duration?.quarterNotes) == [.string("2/1"), .string("1/1"), .string("1/1")])
    let bytes = [UInt8](try #require(result.artifact(.midi)?.data))
    #expect((0..<(bytes.count - 2)).filter { Array(bytes[$0...($0 + 2)]) == [0xFF, 0x51, 0x03] }.count == 3)
}

@Test func fermataRejectsInvalidFactorsAndSectionOverflow() {
    for directive in ["fermata q factor 1; C4 w", "C4 w; fermata q factor 2"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(directive) } } }
            main { s }
            """, fileID: "invalid-fermata.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded, "\(directive)")
    }
}

@Test func resolvedRubatoAppliesDeterministicLocalTimeFactors() throws {
    let result = UTabTextCompiler().compile(TextSource("""
        import instruments.piano
        meter 4/4
        tempo 100
        instrument piano : Piano
        section s { piano { voice v {
            rubato q factor 0.8
            C4 q
            rest q
            rubato q factor 1.25
            D4 q
            E4 q
        } } }
        main { s }
        """, fileID: "rubato.utab"), modules: StandardTextModuleProvider(), options: .init(outputs: [.midi]))
    #expect(result.succeeded, "\(result.diagnostics)")
    let map = try #require(result.document?.setup.time?.tempoMap)
    #expect(map.map(\.quarterNotesPerMinute) == [125, 100, 80, 100])
    #expect(map.map { $0.at?["beat"] } == [.number(1), .number(2), .number(3), .number(4)])
    let events = try #require(result.document?.tracks.first?.parts?.first?.events)
    #expect(events.compactMap(\.duration?.quarterNotes) == [.string("1/1"), .string("1/1"), .string("1/1")])
}

@Test func resolvedRubatoRejectsInvalidFactorsAndSectionOverflow() {
    for directive in ["rubato q factor 0; C4 w", "C4 w; rubato q factor 1.1"] {
        let result = UTabTextCompiler().compile(TextSource("""
            import instruments.piano
            meter 4/4
            tempo 100
            instrument piano : Piano
            section s { piano { voice v { \(directive) } } }
            main { s }
            """, fileID: "invalid-rubato.utab"), modules: StandardTextModuleProvider())
        #expect(!result.succeeded, "\(directive)")
    }
}
