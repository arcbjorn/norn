# Roadmap

## Strategy

Build vertical slices that prove the risky properties early:

1. Odin can drive the chosen native graphics stack reliably.
2. A large trace can be normalized and reopened quickly.
3. File history can be reconstructed faithfully.
4. The interface makes a failed session easier to diagnose.

Do not start with provider breadth, collaboration, live capture, or visual
effects. Each milestone ends with a demonstrable user capability.

## Phase 0: technical spikes

### Goal

Retire foundational risk before committing to the full architecture.

### Work

- Pin an Odin compiler version.
- Open an SDL3 window and render batched primitives through WGPU on macOS.
- Render crisp text at standard and high-DPI scales.
- Parse a generated 100,000-record JSONL stream with bounded memory.
- Memory-map and query a prototype columnar event file.
- Apply and verify a sequence of text patches.
- Test candidate compression codecs on representative text and blob data.
- Record dependency versions, licenses, binary distribution implications, and
  Linux feasibility.

### Exit criteria

- The graphics spike runs for 30 minutes without resource growth or validation
  errors.
- Timeline pan and zoom remain interactive with 100,000 generated events.
- The codec prototype reopens without parsing JSON.
- Patch reconstruction matches every expected content hash.
- Decisions 001, 002, and 006 are confirmed or amended.

The spike code may be discarded. Its measurements and decisions remain.

## Phase 1: canonical import and CLI

### Goal

Turn one sanitized Codex source trace into a validated `.norn` file.

### Work

- Implement canonical identifiers, events, entities, spans, payloads, and edges.
- Implement streaming JSONL ingestion and schema detection.
- Add redaction and import reporting.
- Implement strings, blobs, events, payloads, directory, and footer chunks.
- Add required lookup indexes.
- Implement `norn import`, `inspect`, and `validate`.
- Establish tiny and representative fixture suites.

### Exit criteria

- Identical input produces identical canonical-content digests.
- Full validation detects every corruption fixture.
- Unsupported records are preserved or explicitly counted.
- Import never writes a complete-looking destination after failure.
- The representative trace can be inspected without the source JSONL.

## Phase 2: replay engine

### Goal

Reconstruct repository text at any recorded mutation.

### Work

- Capture and verify repository baseline content.
- Implement the virtual path map and content-addressed blobs.
- Apply create, modify, delete, and rename mutations.
- Add strict unified-patch support.
- Implement snapshots and seek caching.
- Add time-range file comparisons.
- Surface gaps and later recovery.

### Exit criteria

- Every replay golden matches expected content at every checkpoint.
- Forward, backward, and snapshot-based seek agree.
- Replay performs no writes to the fixture repository.
- Reference-fixture file seek meets the p95 budget.

## Phase 3: native investigation workspace

### Goal

Make a large imported session navigable.

### Work

- Implement application state and global selection.
- Build virtualized, multiresolution timeline lanes.
- Add event inspector and import-warning views.
- Add file tree, diff viewer, command output, and test-result panels.
- Implement keyboard navigation, filters, and text search.
- Persist local preferences and recent files.

### Exit criteria

- A user can open, navigate, search, and replay the representative session
  without using the CLI.
- Every panel remains synchronized to the global time selection.
- The reference fixture meets frame and interaction budgets.
- Core investigation is possible using only the keyboard.

## Phase 4: evidence and diagnosis

### Goal

Navigate from a failed outcome to useful, defensible contributor candidates.

### Work

- Parse the structured outcomes present in reference fixtures.
- Build explicit and reconstructed evidence edges.
- Implement comparable-outcome windows.
- Implement versioned contributor rules and evidence explanations.
- Add attempt and retry-loop detection.
- Build the focused repository graph.

### Exit criteria

- Selecting each known fixture failure produces the expected ranked evidence.
- The UI distinguishes explicit, reconstructed, and inferred relationships.
- Every score expands into its deterministic rule contributions.
- Replay gaps visibly cap confidence.

## Phase 5: export and first release

### Goal

Ship a safe, useful macOS release.

### Work

- Implement redacted HTML and canonical JSON export.
- Add annotation overlays and bookmarks.
- Complete accessibility and reduced-motion baseline.
- Add crash-safe preferences and import cleanup.
- Establish packaging, signing, and release automation.
- Write root README, SECURITY, license, and fixture provenance files.
- Run security, compatibility, and performance gates.

### Exit criteria

- A developer can diagnose and export the reference failed session end to end.
- The application runs offline in a clean macOS user account.
- Opening all hostile fixtures causes no execution, repository writes, crashes,
  or unbounded allocation.
- Release artifacts are reproducible enough to verify source revision and
  dependency versions.

## Post-1.0 candidates

Candidates are deliberately unordered until real usage identifies the largest
constraint:

- live tailing of an active session;
- additional provider importers;
- Linux and Windows packages;
- session-to-session comparison;
- richer language-aware symbol mapping;
- optional model-assisted explanations over selected evidence;
- portable annotation overlays;
- plugin-free editor navigation integrations;
- WASM trace viewer for sanitized shared reports.

These candidates do not belong in version one unless required to complete the
core diagnosis workflow.

## Explicitly deferred

- executing or controlling agents;
- automatically fixing discovered failures;
- cloud accounts and synchronization;
- team permissions and hosted trace storage;
- generalized OpenTelemetry ingestion;
- mobile applications;
- three-dimensional graph rendering;
- real-time collaborative cursors.
