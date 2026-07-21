# Quality

## Quality model

Norn's highest-risk areas are parser safety, replay correctness, temporal
ordering, and misleading analysis. Visual polish cannot compensate for a trace
that silently reconstructs the wrong file.

Tests are organized by invariant rather than by implementation package alone.

## Test layers

### Unit tests

Required for:

- checked arithmetic and bounds;
- path normalization;
- string and blob interning;
- timestamp repair;
- event and edge validation;
- patch application;
- mutation chains and rename behavior;
- contributor scoring rules;
- viewport transforms and hit testing;
- redaction rules;
- container header and chunk codecs.

### Golden tests

Golden fixtures assert stable outputs for:

- source trace to canonical summary;
- canonical records to `.norn` bytes after excluding permitted volatile fields;
- replayed file content at selected sequences;
- import warnings and capability manifests;
- exported report data;
- deterministic graph seed positions.

Golden updates require review of a human-readable semantic diff. A command that
blindly replaces every expected file is not an acceptable review workflow.

### Corruption tests

For every container structure, test:

- truncated input at each boundary;
- invalid magic and version;
- offset and size overflow;
- overlapping columns;
- checksum mismatch;
- decompression bomb declaration;
- duplicate identifiers;
- missing references;
- cyclic spans and edges;
- invalid UTF-8 and paths;
- unfinalized files.

Failures must be deterministic and must not panic or allocate beyond limits.

### Replay property tests

Generate bounded random text files and valid mutation sequences. Assert:

- sequential replay equals replay from every valid snapshot;
- seeking forward and backward yields identical state;
- applying inverse test operations restores the baseline where defined;
- rename preserves content identity;
- a full-content event can recover from a prior replay gap;
- reported hashes match produced bytes.

### UI tests

Most interaction behavior is tested below the GPU boundary:

- command routing;
- selection synchronization;
- filter semantics;
- viewport range queries;
- keyboard navigation;
- visible-row virtualization;
- evidence-stack ordering.

Rendering tests produce deterministic off-screen images for a small set of
critical scenes. Image comparison uses a documented tolerance and stores a diff
artifact on failure.

### End-to-end tests

An end-to-end fixture exercises:

1. import sanitized JSONL;
2. validate the completed trace;
3. reopen it;
4. seek to known sequences;
5. reconstruct known files;
6. select a failing test;
7. obtain expected contributor candidates;
8. export a report;
9. validate the export manifest.

## Fixture tiers

| Tier | Size | Use |
| --- | ---: | --- |
| Tiny | under 100 events | Unit and error-path tests |
| Representative | 1,000-10,000 events | Golden and end-to-end tests |
| Reference | 100,000 events | Release performance gate |
| Stress | 1,000,000 events | Manual and scheduled scalability test |

Large fixtures are generated deterministically when possible. Any checked-in
binary fixture needs provenance, license, generator version, and expected hash.

## Benchmarks

Benchmarks measure:

- JSONL records parsed per second;
- canonical events written per second;
- trace open and validation time;
- time-range and entity query latency;
- replay seek latency by mutation distance;
- diff latency by file size;
- search latency;
- graph-layout convergence time;
- frame CPU and GPU time;
- peak resident memory during import and viewing.

Results include machine and compiler details. A single local number is not a
portable promise.

## Release gates

A release candidate must pass:

- formatter and compiler checks;
- all unit, golden, corruption, replay, and end-to-end tests;
- full validation of every checked-in `.norn` fixture;
- zero known path-escape or execution-on-open behavior;
- reference performance budgets or an explicitly approved exception;
- manual keyboard workflow check;
- manual redaction and export review;
- clean import under a fresh user-data directory;
- documentation consistency check.

## Compatibility tests

Once format version one is stable, every release keeps at least one trace
written by each prior minor writer. Current readers must open them. A new writer
must not rewrite an old trace merely because it was opened.

## Bug reports

A useful bug report includes:

- Norn version and commit;
- OS and architecture;
- importer identifier and source schema classification;
- sanitized minimal fixture or generated reproducer;
- expected and actual behavior;
- `norn validate` result;
- whether the issue reproduces without GPU rendering.

Private source traces must not be attached to public issues.
