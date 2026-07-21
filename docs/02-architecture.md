# Architecture

## Overview

Norn is a local desktop application with an offline import pipeline and a
read-only replay runtime. It uses Odin for the application, canonical model,
storage codec, analysis, and rendering.

```text
Provider trace     Repository
      |                 |
      v                 v
+-------------+   +-------------+
| Importer    |   | Baseline    |
| adapter     |   | resolver    |
+------+------+   +------+------+
       |                 |
       +--------+--------+
                v
       +-----------------+
       | Canonical model |
       +--------+--------+
                |
                v
       +-----------------+
       | .norn writer    |
       +--------+--------+
                |
                v
       +-----------------+
       | Mapped trace    |
       +---+---------+---+
           |         |
           v         v
      Replay       Analysis
           |         |
           +----+----+
                v
          Native UI / export
```

The import path may write a new trace. The viewing path treats both the trace
and repository as read-only.

## Runtime processes

Version one is a single OS process with bounded worker threads:

- the main thread owns the window, input, UI state, and GPU submission;
- an I/O worker reads and decodes trace chunks;
- an analysis worker builds indexes and derived edges;
- an import worker pool parses source records and hashes file content;
- an export worker writes reports.

Workers communicate through bounded queues. UI work must never wait on disk,
compression, parsing, repository scanning, or graph layout.

No background service is required. Norn does not listen on a network port.

## Package boundaries

The intended source layout is:

```text
src/
  main/                 executable entry point and CLI dispatch
  app/                  lifecycle, commands, global selection
  platform/             window, paths, file watching, clipboard, dialogs
  importers/
    api/                importer contract and detection
    codex/              first source adapter
  trace/
    model/              canonical semantic types
    codec/              .norn reader and writer
    index/              time, entity, text, and blob indexes
  replay/               virtual repository and mutation application
  analysis/             spans, outcomes, correlations, causal candidates
  render/               GPU resources, batching, text, graph primitives
  ui/                   panels, layout, commands, themes, accessibility
  export/               diagnostic bundle generation
tests/
  fixtures/
  golden/
  performance/
```

Dependencies flow inward toward `trace/model`. In particular:

- canonical model code imports no UI or provider package;
- importers produce canonical records but canonical code knows no importers;
- replay consumes canonical mutations and baseline content;
- analysis consumes canonical events and replay metadata;
- UI reads stable query interfaces instead of trace-file offsets;
- renderer receives draw data and owns no product state.

Circular package dependencies are prohibited.

## Major components

### Import coordinator

Detects the source format, collects repository identity, applies redaction,
normalizes events, validates invariants, and writes a temporary `.norn` file.
The file is atomically renamed only after validation succeeds.

### Trace store

Memory-maps immutable trace regions where supported and lazily decodes chunks.
It exposes typed queries:

- event by identifier;
- events in a time range;
- events for an entity;
- children of a span;
- mutations for a path;
- blob by content hash;
- diagnostics for a command or test run.

Callers do not parse container bytes directly.

### Virtual repository

Reconstructs files from a verified baseline and ordered mutation records. It
uses periodic snapshots and forward application to bound seek time. It never
writes reconstructed content into the user's repository.

### Analysis engine

Builds deterministic indexes and evidence edges. Expensive analyses run once
after import or incrementally in the background and are cached as derived
chunks. Derived data can be discarded and rebuilt.

### Application state

Owns the global selection, open panels, active filters, theme, and ephemeral
layout state. Persistent preferences live outside traces. Session annotations
are stored as a separate overlay so opening a trace does not mutate it.

### Renderer

Uses SDL3 for windows and input and WGPU for cross-platform GPU rendering. The
renderer batches rectangles, lines, glyphs, and graph geometry. UI widgets are
implemented in Norn because virtualized timelines and synchronized selection
are central product behavior, not generic form controls.

## Data ownership

Long-lived allocations use explicit allocators:

| Lifetime | Allocation strategy |
| --- | --- |
| Application | General-purpose allocator |
| Open trace | Trace arena, released when trace closes |
| Decoded chunk cache | Size-bounded LRU allocator |
| Frame | Resetting frame arena |
| Import batch | Resetting batch arena |
| Replay result | Caller-provided or replay-cache allocator |

Pointers into mapped or cached chunks must not escape their lease. Stable
application state stores identifiers, not raw pointers to trace records.

## Concurrency rules

- The main thread is the only writer to application and UI state.
- Trace bytes are immutable after publication.
- Worker results cross threads as owned messages.
- A worker cannot retain a frame allocator allocation.
- Cancellation is explicit and checked between batches.
- Closing a trace cancels workers before releasing its arena or mapping.
- Graph layout publishes complete snapshots; the renderer never reads a
  partially updated layout.

## Error model

Expected failures use typed error unions or explicit result structures. Fatal
process termination is reserved for failure to initialize the application or
an invariant violation that makes continued operation unsafe.

Errors crossing package boundaries include:

- stable category;
- human-readable message;
- source path or event identifier when available;
- recoverability;
- underlying platform detail for logs.

Provider-specific error strings do not become application control flow.

## Platform strategy

The first platform is macOS on Apple Silicon. Platform-specific functionality
is hidden behind `platform` interfaces. Linux support must not require changing
the trace model, codec, replay engine, analysis, or UI semantics.

## External dependencies

Dependencies are deliberately narrow:

- SDL3: windows, input, clipboard, and platform integration;
- WGPU: portable GPU rendering;
- a font rasterizer from Odin's supported vendor set;
- optional native compression library selected by the trace-format spike.

Git operations needed for import should prefer invoking `git` with a fixed,
argument-vector interface in the importer process. This avoids making libgit2 a
foundational dependency. Norn never invokes Git while merely viewing a trace.

Every dependency is pinned and documented. Updating one requires fixture and
performance validation.
