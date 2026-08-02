# Norn

Norn is a native time-travel debugger for coding-agent sessions. It imports an
agent trace, reconstructs how the repository changed, and presents prompts,
tool calls, edits, commands, tests, and errors on one navigable timeline.

The full specification lives in [`docs/`](docs/README.md). Start with
[Product](docs/00-product.md) and [Architecture](docs/02-architecture.md).

## Status

Early implementation. The canonical trace model, the `.norn` container codec,
the replay engine, and the `inspect` and `validate` CLI commands work. The
importer and native UI are not built yet.

| Area | State |
| --- | --- |
| Core safety (checked arithmetic, paths, limits, CRC32C) | Implemented |
| Canonical model (events, entities, spans, edges, mutations) | Implemented |
| String interning and content-addressed blobs | Implemented |
| `.norn` writer, reader, and validator | Implemented |
| Virtual repository and mutation replay | Implemented |
| Strict unified-patch application | Implemented |
| Snapshots, seeking, and range comparison | Implemented |
| `norn inspect` / `norn validate` (all three modes) | Implemented |
| Codex importer | Not started |
| Analysis and contributor scoring | Not started |
| Native UI (SDL3 + WGPU) | Not started |

Replay currently starts from an empty baseline, because capturing a repository
baseline is the importer's job and the importer does not exist yet. A patch
against a file replay has never seen is therefore a `missing_baseline` gap —
the honest result for a trace that carries no baseline.

## Requirements

- Odin `dev-2026-07` (pinned in [`.odin-version`](.odin-version))
- Clang and the macOS command-line tools

SDL3 is required only once the renderer lands.

```sh
brew install odin
```

## Commands

All development commands route through one script, so CI and developers invoke
the same thing:

```sh
scripts/norn.sh build [debug|release|sanitize|profile]
scripts/norn.sh test [package]
scripts/norn.sh check
scripts/norn.sh clean
```

The product CLI:

```sh
norn inspect <trace.norn> [--json]
norn validate <trace.norn> [--mode quick|full|replay]
```

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
tests/
  core/    arithmetic, path safety, checksum vectors
  model/   interning and blob identity
  codec/   roundtrip, determinism, and corruption fixtures
  replay/  patching, mutation chains, and seek properties
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

Replay adds its own rule: patch application is strict. A hunk whose context
does not match exactly produces a labeled gap, never relocated or fuzzy-matched
content. Reconstructing a file at the wrong offset would produce bytes the
session never had, and the user could not tell by looking.

## Testing

```sh
scripts/norn.sh test
```

112 tests across four packages. See [Quality](docs/09-quality.md) for the
intended test layers and release gates.
