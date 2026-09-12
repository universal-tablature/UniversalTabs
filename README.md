# Universal Tablature

[![Build](https://github.com/universal-tablature/UniversalTabs/actions/workflows/build.yml/badge.svg)](https://github.com/universal-tablature/UniversalTabs/actions/workflows/build.yml)

Universal Tablature is a pair of formats for describing music for conventional,
virtual, and mechanically actuated instruments:

- `.utab` is a high-level composition language for musical intent, reusable
  phrases, parts, voices, and arrangements.
- `.utab.json` is the resolved interchange format for timing, instrument setup,
  actuator events, and source information.

This repository contains the Swift libraries, compiler, language server, MIDI
and MusicXML converters, instrument standard library, schemas, examples, and
supporting command-line tools.

## Requirements

- Swift 6.3
- macOS, Linux, or Windows
- The zlib development package on Linux

The ZIP-dependent PDMX utilities are supported on macOS and Linux. The other
libraries and tools build on all three platforms.

## Build and test

```console
git clone https://github.com/universal-tablature/UniversalTabs.git
cd UniversalTabs
swift build --configuration release
swift test
```

Use SwiftPM to print the platform-specific directory containing the compiled
executables:

```console
swift build --configuration release --show-bin-path
```

## Command-line tools

| Tool | Purpose | Platforms |
| --- | --- | --- |
| `utabc` | Compile `.utab` source to Universal Tablature JSON or MIDI | macOS, Linux, Windows |
| `utab-lsp` | Run the language server over LSP/JSON-RPC on standard input and output | macOS, Linux, Windows |
| `utab-midi` | Convert `.utab.json` documents to Standard MIDI files | macOS, Linux, Windows |
| `utab-musicxml` | Import MusicXML or export Universal Tablature JSON as MusicXML | macOS, Linux, Windows |
| `utab-lilypond` | Export UTAB JSON to LilyPond, optionally rendering and opening PDF output | macOS, Linux, Windows |
| `utab-mei` | Import or export MEI 5.1 | macOS, Linux, Windows |
| `utab-mnx` | Import or export the experimental MNX 1.0 draft (not a final specification) | macOS, Linux, Windows |
| `utab-decompile` | Decompile UTAB JSON to standalone UTAB composer source | macOS, Linux, Windows |
| `utab-convert` | Autodetect and convert between UTAB, UTAB JSON, MEI, LilyPond, MusicXML, and MNX | macOS, Linux, Windows |
| `utab-pdmx-index` | Index a PDMX dataset | macOS, Linux |
| `utab-pdmx-import` | Import indexed PDMX entries | macOS, Linux |
| `utab-pdmx-validate` | Round-trip indexed PDMX entries through UTAB and MusicXML | macOS, Linux |

For example:

```console
swift run utabc --emit utab-json score.utab
swift run utabc --emit midi -o score.mid score.utab
swift run utab-midi score.utab.json score.mid
swift run utab-musicxml import score.musicxml score.utab.json
```

Run a tool with `--help` for its current options where supported.

## Documentation

The [Universal Tablature website](https://universal-tablature.github.io/)
contains the language references, standard-library documentation, tutorials,
examples, and installation guide. Specifications and additional design material
are also maintained in this repository.

## License

UniversalTabs is licensed under the [Apache License 2.0](LICENSE). Vendored and
third-party dependencies remain subject to their respective licenses.
