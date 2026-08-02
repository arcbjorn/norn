# Decisions

## How to use this document

This is the compact architectural decision ledger. Accepted decisions are the
default until evidence justifies a replacement. A replacement keeps the old
entry, marks it superseded, and names the new decision.

| ID | Decision | Status |
| --- | --- | --- |
| 001 | Use Odin for the application and core systems | Accepted |
| 002 | Use SDL3 plus WGPU for the native frontend | Accepted |
| 003 | Keep version one local and offline | Accepted |
| 004 | Normalize providers into one canonical model | Accepted |
| 005 | Use an immutable append-only `.norn` container | Accepted |
| 006 | Use columnar event storage and content-addressed blobs | Provisional |
| 007 | Replay in a virtual repository | Accepted |
| 008 | Treat causal relationships as evidence-ranked candidates | Accepted |
| 009 | Support one Codex trace family first | Accepted |
| 010 | Keep raw provider records optional | Accepted |
| 011 | Build a custom investigation UI | Accepted |
| 012 | Target macOS first | Accepted |
| 013 | Keep analysis deterministic in version one | Accepted |
| 014 | Store annotations outside immutable traces | Accepted |

## 001: Odin for application and core systems

**Decision:** Implement the executable, canonical model, codec, replay engine,
analysis, renderer, and UI in Odin.

**Reason:** Norn's main technical problems are explicit memory ownership,
high-volume data processing, native interoperability, and GPU visualization.
Using one systems language across those boundaries keeps data layouts and
ownership visible.

**Consequence:** The project accepts a smaller ecosystem and must maintain
careful dependency pins and native build documentation.

## 002: SDL3 plus WGPU

**Decision:** Begin with SDL3 for platform behavior and WGPU for rendering.

**Reason:** The pairing provides a narrow platform layer and a portable modern
GPU API while leaving product UI under Norn's control.

**Status:** Accepted. The phase-zero spike validated the pairing on macOS:
Metal backend, high-DPI at 2.0x scale, and 0.31 ms per frame to build 100,000
timeline instances against an 8 ms budget. See
[Spike results](13-spike-results.md).

**Consequence:** wgpu-native is not vendored for macOS by Odin and the
Homebrew package reports a version the bindings reject, so the project must
pin and fetch the upstream release binary itself. Text rendering at high DPI
remains unproven and is the next spike.

## 003: local and offline

**Decision:** Import, replay, analysis, search, and export require no service or
network access.

**Reason:** Traces can contain private prompts, source code, command output, and
credentials. Local operation also reduces initial product and operational scope.

**Consequence:** Sharing occurs through explicit redacted export artifacts.

## 004: canonical provider-neutral model

**Decision:** Provider schemas terminate at importer adapters.

**Reason:** Rendering or analysis coupled to one provider would make every
schema change a cross-application migration and prevent meaningful comparison.

**Consequence:** The canonical model must express unknown extension records and
source provenance without pretending to understand them.

## 005: immutable append-only container

**Decision:** A completed `.norn` trace is immutable. Import writes a new file;
viewing does not modify it.

**Reason:** Immutability makes memory mapping, caching, sharing, validation, and
evidence integrity simpler.

**Consequence:** Annotations and user layout state live in separate overlays.

## 006: columnar events and content-addressed blobs

**Decision:** Store hot fixed-width event fields in columns and large variable
content as independently addressable blobs.

**Reason:** Timeline queries touch a few fields across many events, while replay
loads a small number of large values. One row-oriented representation serves
neither access pattern well.

**Status:** Provisional until the codec spike measures complexity, file size,
open latency, and query performance against a simpler baseline.

## 007: virtual repository replay

**Decision:** Reconstruct historical state in memory from baseline content,
mutations, and snapshots.

**Reason:** Checking out history or applying patches in the source repository is
unsafe and makes viewing dependent on mutable external state.

**Consequence:** Norn must explicitly represent missing baselines, unsupported
patches, hash mismatches, and recovery after gaps.

## 008: evidence-ranked causal candidates

**Decision:** Norn presents explicit relationships and deterministic contributor
candidates, not unsupported causal claims.

**Reason:** Temporal proximity alone does not establish causality. Misleading
confidence would make the debugger less trustworthy than the transcript.

**Consequence:** Every inferred edge stores its rule, evidence, and score, and
the interface uses careful language.

## 009: one Codex trace family first

**Decision:** Version one supports a fixture-defined Codex JSONL schema family
before adding other providers.

**Reason:** Replay and investigation depth matter more than a shallow list of
formats. The adapter contract still prevents Codex assumptions from leaking.

**Consequence:** Unsupported variants are detected and reported instead of being
silently parsed on a best-effort basis.

## 010: optional raw records

**Decision:** Raw provider-record retention is opt-in and redacted before write.

**Reason:** Raw records help adapter debugging but substantially increase
privacy exposure and trace size.

**Consequence:** Canonical provenance works without raw data; exact source audit
requires the user to enable retention at import time.

## 011: custom investigation UI

**Decision:** Build the timeline, synchronized panels, graph, and diff workspace
as a native Norn interface instead of embedding a browser UI.

**Reason:** Large-scale virtualization, time-linked panels, precise hit testing,
and GPU graph interaction are core behavior.

**Consequence:** Accessibility, text input, layout, and widget behavior are
project responsibilities and must be scheduled explicitly.

## 012: macOS first

**Decision:** The first supported release target is Apple Silicon macOS, with
Linux next and Windows architecturally possible.

**Reason:** A single first platform keeps packaging, high-DPI, input, and GPU
debugging bounded while the interaction model is still changing.

**Consequence:** Platform functionality stays behind interfaces from the first
commit; macOS behavior must not leak into trace semantics.

## 013: deterministic analysis

**Decision:** Version-one search, attempt detection, comparison, and contributor
ranking use deterministic algorithms without an LLM dependency.

**Reason:** The debugger must reproduce explanations, work offline, and show why
each result exists.

**Consequence:** Model-assisted explanation remains a later optional layer over
selected evidence, never the source of canonical facts.

## 014: external annotation overlays

**Decision:** Bookmarks, notes, and local UI annotations are stored in a sidecar
identified by the trace content digest.

**Reason:** User notes should not invalidate the imported evidence artifact or
force the entire trace to be rewritten.

**Consequence:** Moving a trace requires moving or exporting its overlay when
annotations matter. Missing overlays do not affect trace validity.

## 015: baseline absence is an observation, not a default

**Decision:** The baseline manifest records three distinct outcomes per path —
content was read, absence was observed, or nothing was observed. A path Norn
could not read produces no manifest entry at all rather than an entry claiming
absence.

**Reason:** docs/06 requires that the manifest "must not imply that unobserved
paths were absent." The two collapse easily in code, because both arrive as a
failed read. But they are different claims to the user: observed absence lets
replay treat a later create as legitimate, while an unread path is a gap. A
symlink pointing outside the repository is the sharp case — the boundary check
refuses it, and recording that as absence would assert a file did not exist when
it plainly does.

**Consequence:** The existence probe returns three states rather than a boolean,
and binary files — deliberately not stored — produce no entry either, because
the schema cannot express "present, content intentionally omitted". Those paths
replay as gaps, which is the honest outcome for content Norn chose not to keep.

## Open questions

These require spikes or user evidence rather than immediate decisions:

1. Which compression codec best balances bindings, distribution, safety, and
   random blob access?
2. Should graph layout use a CPU worker initially or a GPU compute pipeline?
3. Which exact Codex schema variants can be supported from stable sanitized
   fixtures?
4. Is a custom lexical highlighter sufficient for version one, or should Norn
   bind Tree-sitter during the first release?
5. What annotation sidecar format provides atomic updates without becoming a
   second complex database?
6. What repository-size threshold requires a disk-backed replay cache?
