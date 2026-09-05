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
    for body in ["using notation German", "phrase a { C4 q; using notation German; H4 q }", "phrase a { using notation German; using notation German; H4 q }", "phrase a { using notation Missing }", "phrase a { using notation German; Z4 q }", "phrase a { H4 q }"] {
        let loaded = TextModuleLoader().load(root: TextSource("import std.naming.western.german; meter 4/4; tempo 100; \(body)"), provider: StandardTextModuleProvider())
        #expect(!loaded.succeeded || !TextSemanticLowerer().lower(loaded.modules).succeeded, "\(body)")
    }
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
