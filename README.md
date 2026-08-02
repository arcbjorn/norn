# Norn

Norn is a native time-travel debugger for coding-agent sessions. It imports an
agent trace, reconstructs how the repository changed, and presents prompts,
tool calls, edits, commands, tests, and errors on one navigable timeline.

The full specification lives in [`docs/`](docs/README.md). Start with
[Product](docs/00-product.md) and [Architecture](docs/02-architecture.md).

## Status

Early implementation. The canonical trace model, the `.norn` container codec,
the replay engine, evidence analysis, and redacted export all work, along with
the `inspect`, `validate`, `explain`, and `export` CLI commands. The importer
and native UI are not built yet.

| Area | State |
| --- | --- |
| Core safety (checked arithmetic, paths, limits, CRC32C) | Implemented |
| Canonical model (events, entities, spans, edges, mutations) | Implemented |
| String interning and content-addressed blobs | Implemented |
| `.norn` writer, reader, and validator | Implemented |
| Virtual repository and mutation replay | Implemented |
| Strict unified-patch application | Implemented |
| Snapshots, seeking, and range comparison | Implemented |
| Typed event payloads (diagnostics, commands, tests) | Implemented |
| Comparable outcomes and candidate windows | Implemented |
| Versioned contributor scoring and evidence stacks | Implemented |
| Attempt and retry-loop detection | Implemented |
| Redacted HTML and canonical JSON export | Implemented |
| `norn inspect` / `validate` / `explain` / `export` | Implemented |
| Codex importer | Not started |
| Annotation overlays and bookmarks | Not started |
| SDL3 + WGPU stack validation (decision 002) | Confirmed |
| Text rendering and glyph atlas validation | Confirmed |
| Native UI (timeline, panels, diff viewer) | Not started |

Replay currently starts from an empty baseline, because capturing a repository
baseline is the importer's job and the importer does not exist yet. A patch
against a file replay has never seen is therefore a `missing_baseline` gap —
the honest result for a trace that carries no baseline.

## Requirements

- Odin `dev-2026-07` (pinned in [`.odin-version`](.odin-version))
- Clang and the macOS command-line tools

```sh
brew install odin
```

The CLI needs nothing further. Building the graphics spike (and eventually the
UI) also needs SDL3 and wgpu-native:

```sh
brew install sdl3
scripts/bootstrap-graphics.sh
```

`bootstrap-graphics.sh` compiles Odin's vendored stb sources and fetches the
pinned upstream wgpu-native release. Odin ships neither ready to use on macOS,
and the Homebrew wgpu package reports a version its bindings reject — see
[Spike results](docs/13-spike-results.md).

## Commands

All development commands route through one script, so CI and developers invoke
the same thing:

```sh
scripts/norn.sh build [debug|release|sanitize|profile]
scripts/norn.sh test [package]
scripts/norn.sh check
scripts/norn.sh spike graphics [--frames N] [--events N]
scripts/norn.sh spike text [--frames N]
scripts/norn.sh clean
```

The product CLI:

```sh
norn inspect <trace.norn> [--json]
norn validate <trace.norn> [--mode quick|full|replay]
norn explain <trace.norn> --list
norn explain <trace.norn> --event <id>
norn export  <trace.norn> --out <dir> [--range start:end] [--event <id>]
```

`explain` is the diagnosis workflow: select a failed outcome and it reports the
evidence behind it, separated into explicit, reconstructed, and inferred
levels, with every candidate score expanding into the deterministic rules that
produced it. Candidates are labeled candidates, never causes.

`export` writes that same evidence as a self-contained HTML report plus
canonical JSON. It prints an inclusion manifest before writing, excludes prompt
text and raw provider records by default, and creates files readable only by
their owner.

Machine-readable output goes to stdout and diagnostics to stderr, so
`norn inspect --json` can be piped without filtering. Exit codes: `0` success,
`2` usage, `3` unreadable input, `4` invalid trace, `5` unsupported feature.

## Repository layout

```text
docs/     product and engineering specification
src/
  core/          checked arithmetic, errors, limits, paths, CRC32C
  main/          CLI entry point and commands
  trace/
    model/       canonical semantic types, interning, blobs
    codec/       .norn reader, writer, and validator
  replay/        virtual repository, patching, seeking, comparison
  analysis/      outcomes, comparability, scoring, evidence, attempts
  export/        bundle assembly, HTML report, canonical JSON
tests/
  core/    arithmetic, path safety, checksum vectors
  model/   interning and blob identity
  codec/   roundtrip, determinism, and corruption fixtures
  replay/  patching, mutation chains, and seek properties
  analysis/ comparability, scoring weights, and evidence ordering
  export/  encoding, injection resistance, and determinism
spike/    throwaway phase-zero validation programs
scripts/  repeatable developer commands
```

Dependencies flow inward toward `trace/model`. Circular package dependencies
are prohibited.

## Safety properties

These are enforced in code and covered by tests, not merely documented:

- opening a trace executes nothing and writes to no repository;
- every length and offset from untrusted input is overflow-checked before use;
- recorded paths are rejected unless they normalize to repository-relative
  form, and `..` is never resolved against an earlier component;
- checksums are verified before any structured payload is decoded;
- an unfinalized or truncated file is refused rather than partially opened;
- declared decompression ratios are bounded before allocation.

The corruption suite asserts rejection for truncation at every byte boundary,
invalid magic and versions, size overflow, checksum mismatch, declared
decompression bombs, and content tampering that repaired its local checksum.

Exports are self-contained: the HTML report declares a restrictive content
security policy, contains no script element, and references no remote resource,
so a trace containing markup renders as text rather than executing.

Replay adds its own rule: patch application is strict. A hunk whose context
does not match exactly produces a labeled gap, never relocated or fuzzy-matched
content. Reconstructing a file at the wrong offset would produce bytes the
session never had, and the user could not tell by looking.

## Testing

```sh
scripts/norn.sh test
```

173 tests across six packages. See [Quality](docs/09-quality.md) for the
intended test layers and release gates.
