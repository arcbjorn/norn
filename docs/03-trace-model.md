# Trace model

## Purpose

The canonical model separates what happened from how a provider encoded it.
All importers produce this model; replay, analysis, rendering, and export consume
it without provider-specific branches.

## Identifiers

Identifiers are stable within a trace and never reused.

```text
Session_ID   128-bit random identifier
Event_ID     monotonically assigned u64, starting at 1
Span_ID      monotonically assigned u64, 0 means absent
Entity_ID    monotonically assigned u64, 0 means absent
String_ID    index into the interned string table
Blob_ID      content-addressed 256-bit digest
```

The source record identifier is stored separately. Two source records may map
to one canonical event, and one source record may expand into multiple events.

## Time

Each event has:

- `sequence`: total canonical order assigned during import;
- `wall_time_ns`: UTC Unix time when trustworthy, otherwise absent;
- `monotonic_offset_ns`: duration from session start when derivable;
- `duration_ns`: known duration, otherwise absent;
- `time_quality`: exact, derived, repaired, or unknown.

Sequence is authoritative for replay. Wall time is display and correlation
metadata. Importers repair non-monotonic timestamps by preserving source order
and recording a warning; they never silently reorder mutations.

## Event envelope

Every event contains:

```text
Event {
    id
    sequence
    kind
    flags
    wall_time_ns?
    monotonic_offset_ns?
    duration_ns?
    parent_span_id?
    actor_entity_id?
    primary_entity_id?
    summary_string_id?
    payload_ref
    source_ref
}
```

The envelope stays compact and fixed-width in memory. Kind-specific payloads
live in typed column groups rather than a union large enough for every event.

## Event kinds

### Session lifecycle

- `session_start`
- `session_end`
- `phase_start`
- `phase_end`
- `checkpoint`

### Conversation

- `user_message`
- `agent_message`
- `system_message`
- `summary`

Conversation events contain visible text supplied by the trace. Norn does not
invent or infer hidden reasoning events.

### Tools

- `tool_call`
- `tool_result`
- `tool_error`

Tool arguments and results are structured blobs when valid JSON and opaque
text otherwise. A result links to its call through an explicit edge.

### Repository activity

- `file_read`
- `file_create`
- `file_modify`
- `file_delete`
- `file_rename`
- `directory_observe`

Mutation events identify a normalized repository-relative path and include
before and after content hashes when available. A mutation may carry a patch,
full content, or both.

### Processes

- `command_start`
- `command_output`
- `command_end`
- `process_spawn`
- `process_exit`

Commands store an argument vector when the source provides one. A shell command
string remains text and is never parsed as if it were a trustworthy argv.

### Outcomes

- `test_run_start`
- `test_case_result`
- `test_run_end`
- `diagnostic`
- `build_result`
- `lint_result`
- `explicit_error`

An outcome has a status: unknown, running, passed, failed, skipped, cancelled,
or errored. Diagnostics have severity and optional path, line, column, symbol,
and code.

### Control and accounting

- `retry`
- `approval_request`
- `approval_result`
- `token_usage`
- `rate_limit`
- `provider_switch`
- `annotation`

Provider-specific records that have no canonical semantic mapping use
`extension_event`. They retain a namespaced type and raw payload reference but
must not influence core behavior unless an analysis explicitly understands the
namespace.

## Entities

Entities give events stable subjects:

- actor: user, agent, sub-agent, tool, or process;
- repository;
- path;
- symbol;
- command;
- test case or suite;
- diagnostic;
- model/provider;
- external resource.

Entities are immutable descriptions. Time-varying properties are events.

Paths use `/` separators, are relative to the recorded repository root, and
cannot contain `.` or `..` components after normalization. Absolute source paths
may be retained only in redacted provenance metadata.

## Spans

A span groups events belonging to one operation or turn. Spans may nest but may
not form cycles. Typical spans are:

- one agent turn;
- one tool invocation;
- one command execution;
- one test run;
- one importer-recovered edit transaction.

Incomplete spans are valid and flagged. Import must not synthesize a successful
end for a span that simply stops.

## Edges

Edges connect events or entities:

| Edge | Meaning |
| --- | --- |
| `parent` | Explicit structural parent |
| `result_of` | Result produced by a recorded invocation |
| `reads` | Event observed an entity |
| `writes` | Event mutated an entity |
| `renames` | Path identity moved |
| `diagnoses` | Diagnostic refers to a path or symbol |
| `tests` | Test outcome exercises a known entity |
| `precedes` | Ordered relationship used for navigation |
| `candidate_contributor` | Derived evidence-based relationship |
| `supersedes` | Later record replaces an earlier interpretation |

Each edge has an origin:

- explicit: present in source data;
- reconstructed: mechanically derived from spans or mutation data;
- inferred: produced by an analysis rule.

Inferred edges also carry confidence from 0 to 1, a rule identifier, and a
human-readable reason assembled from deterministic fields.

## File mutations

A mutation record contains:

```text
Mutation {
    event_id
    path_entity_id
    old_path_entity_id?
    operation
    encoding
    before_hash?
    after_hash?
    patch_blob_id?
    content_blob_id?
    replay_status
}
```

Text encoding is UTF-8, UTF-16LE, UTF-16BE, binary, or unknown. Norn may display
binary metadata but version one does not reconstruct binary diffs.

Replay status is verified, reconstructed_unverified, missing_baseline,
unsupported_patch, hash_mismatch, or binary_opaque.

## Source provenance

Every canonical event points to a source reference containing:

- importer identifier and version;
- source file identity;
- byte offset or record number;
- source type name;
- optional raw blob identifier;
- transformations applied, including redaction and timestamp repair.

This is required for auditability and importer debugging.

## Invariants

The writer and validator enforce:

1. Event identifiers and sequence numbers strictly increase.
2. Event sequences are unique.
3. Every referenced string, blob, entity, span, and event exists.
4. Parent and result edges are acyclic.
5. Repository paths are normalized and relative.
6. Mutations for one path have a deterministic order.
7. A verified mutation's computed hash matches its recorded hash.
8. Redacted content cannot remain in a preserved raw record.
9. Unknown enum values survive reading and re-export.
10. Derived data never changes the meaning of source events.
