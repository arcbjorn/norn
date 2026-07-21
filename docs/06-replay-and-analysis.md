# Replay and analysis

## Replay contract

For any event sequence and repository-relative path, replay returns one of:

- verified content and its hash;
- reconstructed but unverified content and its evidence;
- known deletion;
- binary or unsupported content metadata;
- an explicit replay gap with the event that introduced it;
- absence because the path did not yet exist.

Replay never consults the current working tree after import. Results depend only
on immutable trace data.

## Virtual repository

The virtual repository models path identity and content identity separately.
This is required for rename chains and identical content at multiple paths.

```text
Path_State {
    path_entity_id
    content_blob_id?
    exists
    encoding
    verification
    last_mutation_event_id?
}
```

A repository state is a persistent map from path entity to `Path_State`.
Snapshots share unchanged substructures where practical.

## Baseline

The strongest baseline is content read from a recorded starting commit and
verified against recorded hashes. A working-tree snapshot is acceptable but is
labeled observational. Missing files are loaded lazily only when a mutation or
view requires them.

The baseline manifest records every path whose absence or content was actually
verified. It must not imply that unobserved paths were absent.

## Applying mutations

Mutation application is deterministic:

1. Resolve the path state immediately before the mutation.
2. Verify `before_hash` when present.
3. Apply operation-specific behavior.
4. Apply a patch strictly or load explicit after content.
5. Compute the result hash.
6. Verify `after_hash` when present.
7. Publish the new immutable path state.
8. Record any gap without corrupting later known states.

Delete requires a known existing path when verification is possible. Rename
preserves content identity and records both paths. A later explicit full-content
mutation can re-establish verified replay after an earlier gap.

## Seeking

Seeking chooses the nearest snapshot at or before the target sequence, then
applies mutations forward only for affected paths. Version-one snapshot policy:

- always snapshot the verified baseline;
- snapshot after every 256 replayable mutations;
- snapshot before and after a phase boundary when the mutation distance is at
  least 64;
- cap snapshot metadata overhead at 10 percent of trace size;
- adapt the interval upward when the cap would be exceeded.

The policy is tunable after measurement. Snapshot content is derived and can be
rebuilt.

## Comparison ranges

For selected sequences `A <= B`, comparison reports:

- paths created, modified, deleted, or renamed;
- before and after hashes;
- aggregated line changes for text;
- commands and outcomes in the interval;
- spans crossing either boundary;
- replay gaps affecting the comparison.

Diff computation is lazy and cached by `(path, A-state-hash, B-state-hash)`.

## Analysis layers

Analysis is separated into three evidence levels.

### Explicit structure

Directly recorded facts:

- tool result belongs to call;
- event belongs to span;
- diagnostic names a path and line;
- mutation names a path;
- test runner names a test case;
- source declares parent or child identifiers.

### Mechanical reconstruction

Relationships that follow deterministically from canonical facts:

- events within one command span;
- path state produced by ordered mutations;
- file changed between comparable test runs;
- diagnostic line falls within a changed hunk;
- command occurred after a mutation and before the next mutation.

### Inferred candidates

Ranked hypotheses useful for navigation:

- an edit may have contributed to a later failing outcome;
- a repeated read-edit-test cycle may be one attempt;
- a later edit may be a repair of an earlier failure;
- repeated identical tool errors may form a retry loop.

The UI always identifies the evidence level.

## Candidate-contributor scoring

For a selected failed outcome, candidate mutations start with edits since the
last comparable passing outcome. If no comparable pass exists, the window begins
at the containing phase or session start.

Version-one score components:

| Signal | Effect |
| --- | ---: |
| Diagnostic directly names edited path | +0.35 |
| Diagnostic line overlaps changed hunk | +0.25 |
| Test-to-file relationship is explicit | +0.20 |
| Mutation is in same agent turn as triggering command | +0.10 |
| File was passed as a direct command argument | +0.10 |
| Mutation is the most recent edit to candidate path | +0.10 |
| A later successful repair modifies same hunk | +0.15 |
| Mutation predates a passing comparable outcome | exclude |
| Replay gap affects relevant content | cap at 0.50 |

Scores are clamped to `[0, 1]`. They rank candidates; they are not probabilities.
Every score is accompanied by the contributing rule identifiers.

Rules and weights are versioned. Changing them invalidates the corresponding
derived chunk, not the canonical trace.

## Comparable outcomes

Two test outcomes are comparable when they have the same stable test identity,
or when the same normalized command and working directory produced structured
results for the same suite. Similar text alone is insufficient.

Build and lint commands use separate comparability rules. A successful formatter
run is not a passing build.

## Attempt detection

An attempt is a derived span beginning with a goal-bearing agent message or an
outcome and ending at one of:

- a successful comparable outcome;
- a new explicit goal;
- a long inactivity boundary;
- session end.

Attempt detection is navigation metadata. It does not rewrite original spans.

## Search indexes

Version one builds:

- exact identifier and path lookup;
- lowercase token index for summaries, paths, commands, and diagnostics;
- trigram index for substring path and symbol search;
- sorted numeric indexes for time, duration, status, and usage.

Large blob text is searched on demand unless explicitly included during import.
Search results carry field and event provenance.

## Analysis cache

Derived results include an algorithm identifier, semantic version, canonical
content digest, and configuration digest. They are reused only when all four
match. A stale analysis is ignored and rebuilt without prompting the user.

## Future extension

A later optional export may send a distilled, source-linked session lesson to
Hugr; Norn must remain fully functional without that integration.
