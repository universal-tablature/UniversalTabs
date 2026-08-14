import Testing
import UTABComposerCore
import UTABComposerDSL

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
