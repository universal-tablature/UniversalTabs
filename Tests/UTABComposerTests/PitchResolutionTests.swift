import Testing
import UTABComposerCore

@Test func scaleResolutionPreservesFineTonicOffsetAndDiatonicSpelling() throws {
    let shiftedD = SpelledPitchClass(.d, tuningOffsetCents: 17)
    let scale = Scale(shiftedD, .major)

    let tonic = try #require(scale.resolve(degree: 1, octave: 4))
    let third = try #require(scale.resolve(degree: 3, octave: 4))
    let octave = try #require(scale.resolve(degree: 8, octave: 4))

    #expect(tonic.spelling == shiftedD)
    #expect(third.spelling == SpelledPitchClass(.f, accidental: 1, tuningOffsetCents: 17))
    #expect(third.cents(relativeTo: tonic) == 400)
    #expect(octave.spelling == shiftedD)
    #expect(octave.octave == 5)
    #expect(octave.cents(relativeTo: tonic) == 1_200)
}

@Test func scaleResolutionRejectsAnEmptyPitchCollection() {
    let empty = Scale(.c, .custom(name: "Empty", centIntervals: []))
    #expect(empty.resolve(degree: 1, octave: 4) == nil)
}
