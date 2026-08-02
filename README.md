# Norn

Norn is a native time-travel debugger for coding-agent sessions. It imports an
agent trace, reconstructs how the repository changed, and presents prompts,
tool calls, edits, commands, tests, and errors on one navigable timeline.

The full specification lives in [`docs/`](docs/README.md). Start with
[Product](docs/00-product.md) and [Architecture](docs/02-architecture.md).

## Status

Early implementation. The canonical trace model, the `.norn` container codec,
the import pipeline, the replay engine, evidence analysis, redacted export, and
the native UI all work. `norn import` converts a session log into a validated
trace, and the whole workflow — import, validate, replay, diagnose, export —
runs end to end.

The one significant gap is a provider adapter. docs/05 requires adapter support
to rest on fixtures rather than assumptions, and pinning a provider schema needs
real sample traces. Until then Norn imports [NSL](docs/14-nsl-format.md), a
session-log format it defines and owns, which exercises every mapping
requirement in the adapter contract and generates the fixture tiers.

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
| Importer contract, record sink, redaction | Implemented |
| Import pipeline and repository identity capture | Implemented |
| Repository baseline capture and replay | Implemented |
| NSL adapter and deterministic fixture generator | Implemented |
| `norn import` | Implemented |
| Codex adapter (needs real sample traces) | Not started |
| Annotation overlays and bookmarks | Not started |
| SDL3 + WGPU stack validation (decision 002) | Confirmed |
| Text rendering and glyph atlas validation | Confirmed |
| Timeline viewport, virtualization, hit testing | Implemented |
| Draw lists, batching, timeline panel | Implemented |
| WGPU backend (pipelines, instance ring, scissor) | Implemented |
| Window, frame loop, keyboard navigation | Implemented |
| Glyph atlas, text layout, lane labels | Implemented |
| Event inspector with evidence stack | Implemented |
| Line diffing and the diff viewer panel | Implemented |
| All four diff comparison modes | Implemented |
| Deterministic graph layout and repository map | Implemented |
| Replay driven from the playhead | Implemented |
| Hostile fixture suite and security gate | Implemented |
| Replay seek benchmark | Implemented |

Import captures a repository baseline: the starting content of every path the
session touched, read from the recorded commit with `git show` when the tree is
clean and from the working tree otherwise, and labelled `commit_verified` or
`working_tree_observational` accordingly. A patch against a file that existed
before the session therefore reconstructs, where it used to be a
`missing_baseline` gap.

The manifest records only what was actually observed. docs/06 forbids implying
that unobserved paths were absent, so three outcomes stay distinct: content was
read, absence was observed, or nothing was observed. A path refused at the
repository boundary — a symlink pointing outside it, say — falls in the third
group and produces no entry at all, because claiming absence for a file that
plainly exists would be a false observation.

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
scripts/norn.sh fixture <tiny|representative|reference|stress> [out]
scripts/norn.sh bench <trace.norn>
scripts/norn.sh spike graphics [--frames N] [--events N]
scripts/norn.sh spike text [--frames N]
scripts/norn.sh spike backend [--frames N]
scripts/norn.sh clean
```

The product CLI:

```sh
norn open    <trace.norn>
norn import  <source> --repo <path> [--format <id>] [--out file.norn] [--dry-run]
norn inspect <trace.norn> [--json]
norn validate <trace.norn> [--mode quick|full|replay]
norn explain <trace.norn> --list
norn explain <trace.norn> --event <id>
norn export  <trace.norn> --out <dir> [--range start:end] [--event <id>]
```

`import` reads a session log and writes a validated `.norn` trace. It never
executes the source or anything named inside it, redacts before writing, and
reports what it repaired, ignored, or replaced. `--dry-run` reports what a
source contains — including record types the adapter cannot map — without
writing output.

`open` launches the desktop application: a virtualized timeline with the
keyboard navigation from [User experience](docs/01-user-experience.md) — arrows
step between events, Shift between mutations, Command between outcomes, Space
plays, brackets set a comparison range, and Escape backs out one layer at a
time. Clicking an event opens it in the inspector, which shows its attributes
and provenance, and for an outcome the ranked evidence behind it. Focusing a file with `F`
reconstructs its content at the playhead in the panel below, labelled with how
much replay could verify. `D` cycles the four comparisons from
[User experience](docs/01-user-experience.md): state at the playhead, since the
previous change, since session start, and across the bracket-selected range.
The repository map on the left shows the files a session touched, sized by
activity and coloured by outcome; clicking one focuses it.

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
  replay/        virtual repository, patching, seeking, comparison, diffing
  analysis/      outcomes, comparability, scoring, evidence, attempts, graph
  app/           selection, commands, replay session, window, frame loop
  render/        draw lists, primitives, batching, fonts, WGPU backend
  ui/            viewport transforms, virtualization, and the four panels
  export/        bundle assembly, HTML report, canonical JSON
  importers/
    api/         adapter contract, record sink, redaction, pipeline
    nsl/         the Norn Session Log adapter
  tools/
    genfixture/  deterministic fixture generation
    bench/       replay seek and reconstruction benchmark
tests/
  core/    arithmetic, path safety, checksum vectors
  model/   interning and blob identity
  codec/   roundtrip, determinism, and corruption fixtures
  replay/  patching, mutation chains, seek properties, diff reconstruction
  analysis/ comparability, scoring weights, evidence ordering, layout
  export/  encoding, injection resistance, and determinism
  importers/ redaction rules, sink invariants, detection, pipeline, digests
  nsl/     adapter mapping, malformed input, streaming bounds
  fixtures/hostile/  adversarial sources for the security gate
  render/  draw list culling, clipping, batching, glyph atlases
  ui/      transform inverses, virtualization, and drawn output
  app/     command routing, keyboard bindings, playback, playhead replay
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

The timeline enforces one more: hit testing and drawing share a single
transform. docs/07 prohibits duplicate coordinate math because two formulas
drift, so clicking always selects what was drawn — asserted by a property test
over a thousand random timestamps.

Replay adds its own rule: patch application is strict. A hunk whose context
does not match exactly produces a labeled gap, never relocated or fuzzy-matched
content. Reconstructing a file at the wrong offset would produce bytes the
session never had, and the user could not tell by looking.

## Testing

```sh
scripts/norn.sh test
```

476 tests across eleven packages, plus 49 CLI contract checks and 122 security
checks against the hostile fixtures. See [Quality](docs/09-quality.md) for the
intended test layers and release gates.

The security gate (`scripts/test-security.sh`) runs every fixture in
`tests/fixtures/hostile` through the built binary and asserts the outcome rather
than the mechanism: no sentinel file was created, the repository hash is
unchanged, no export leaked a secret or produced active markup, and memory
stayed bounded. It found a buffer overflow in JSON string decoding on its first
run — see [Spike results](docs/13-spike-results.md).
