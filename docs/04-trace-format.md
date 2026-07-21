# Trace format

## Status

This document defines the target version-one `.norn` container. The phase-zero
codec spike may change field widths, compression, or alignment before the first
fixture is declared stable. Once a fixture is marked stable, compatibility
follows the rules in this document.

## Goals

The format must support:

- sequential creation from a large source trace;
- fast reopening without reparsing the source;
- time-range and entity queries without decoding all events;
- memory mapping of immutable regions;
- preservation of unknown extension records;
- deterministic output;
- corruption detection;
- safe parsing of untrusted input;
- rebuilding all derived indexes from canonical records.

The format is not intended for in-place editing or network streaming in version
one.

## Byte conventions

- Integers are little-endian.
- File offsets are unsigned 64-bit byte offsets from the beginning of the file.
- Sizes are unsigned 64-bit byte counts unless the field says otherwise.
- Timestamps are signed 64-bit nanoseconds.
- Chunks begin on 64-byte boundaries.
- Reserved fields are zero when written and ignored when read.
- All text is valid UTF-8 unless a blob explicitly declares another encoding.

## File layout

```text
+----------------------+ offset 0
| 64-byte file header  |
+----------------------+
| metadata chunk       |
+----------------------+
| string chunks        |
+----------------------+
| entity/span chunks   |
+----------------------+
| event column chunks  |
+----------------------+
| payload chunks       |
+----------------------+
| blob chunks          |
+----------------------+
| derived chunks       |
+----------------------+
| index directory      |
+----------------------+
| footer               |
+----------------------+ end
```

Chunk order is canonical for deterministic output, though readers locate chunks
through the directory rather than assuming physical order.

## File header

The 64-byte header contains:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic bytes `NORNTRCE` |
| 8 | 2 | Major version |
| 10 | 2 | Minor version |
| 12 | 4 | Header flags |
| 16 | 16 | Session identifier |
| 32 | 8 | Creation Unix time in nanoseconds |
| 40 | 8 | Directory offset |
| 48 | 8 | Footer offset |
| 56 | 4 | Header CRC32C with this field zeroed |
| 60 | 4 | Reserved |

A zero directory or footer offset means the file was not finalized and must not
be opened as a complete trace. Recovery tooling may scan chunks, but the desktop
application reports the file as incomplete.

## Chunk header

Every chunk begins with a fixed 64-byte header:

| Field | Type | Meaning |
| --- | --- | --- |
| magic | `[4]u8` | `NRCK` |
| kind | `u16` | Chunk kind |
| schema_version | `u16` | Payload schema for this kind |
| flags | `u32` | Compression and optionality flags |
| ordinal | `u32` | Stable ordinal among chunks of this kind |
| record_count | `u32` | Logical records in payload |
| encoded_size | `u64` | Stored payload bytes |
| decoded_size | `u64` | Bytes after decompression |
| first_sequence | `u64` | First event sequence, or zero |
| last_sequence | `u64` | Last event sequence, or zero |
| payload_crc32c | `u32` | Checksum of encoded payload |
| header_crc32c | `u32` | Checksum of header with this field zeroed |
| reserved | `[4]u8` | Zero |

Readers reject arithmetic overflow, a payload outside file bounds, unreasonable
decoded sizes, invalid sequence ranges, or checksum mismatches.

## Chunk kinds

Core kinds are:

| Kind | Contents |
| --- | --- |
| `metadata` | Session, repository, importer, warnings, capabilities |
| `strings` | Interned UTF-8 strings and offsets |
| `entities` | Canonical entity rows |
| `spans` | Span rows and parent relationships |
| `events` | Fixed-width event envelopes in columns |
| `payloads` | Kind-specific canonical payload columns |
| `edges` | Explicit and reconstructed edges |
| `blobs` | Content-addressed binary or text values |
| `snapshots` | Replay acceleration points |
| `derived` | Rebuildable analysis output |
| `indexes` | Search and lookup structures |
| `directory` | All chunk locations and properties |
| `footer` | File digest and completion marker |

Unknown optional kinds are skipped and preserved by copy-based tooling. Unknown
required kinds cause a clear unsupported-format error.

## Column encoding

High-cardinality fixed-width fields use structure-of-arrays encoding inside a
chunk. An events chunk stores contiguous columns for identifiers, sequences,
kinds, flags, timestamps, span identifiers, entity identifiers, and payload
references.

Benefits:

- time and kind filtering touch fewer bytes;
- the renderer can copy selected columns efficiently;
- absent optional values use validity bitmaps;
- schema evolution can append optional columns.

Each column declares element width, element count, codec, validity bitmap
offset, and data offset. Readers validate that columns do not overlap or escape
the decoded chunk.

## Strings

Strings are deduplicated by exact UTF-8 bytes. Identifier zero represents the
empty or absent string. A strings chunk contains:

- count;
- `count + 1` offsets;
- concatenated UTF-8 bytes;
- optional hash index in a derived chunk.

The writer normalizes neither case nor Unicode. Paths are normalized before
interning according to the trace-model rules.

## Blobs

Large text, raw records, patches, command output, and file content are blobs.
Each blob entry includes:

- SHA-256 digest used as its stable identifier;
- media type string;
- logical encoding;
- uncompressed size;
- flags for redacted, truncated, or derived content;
- payload location.

Duplicate content is stored once. Blob compression is independent so one blob
can be loaded without decompressing its neighbors. The reader verifies the
digest after decompression before treating content as replay-verified.

## Compression

Version one chooses a single fast, bounded-memory compression codec during the
phase-zero spike. `none` is always supported. The chunk header records the
codec, and readers reject unknown required codecs.

Compression decisions are deterministic for the same writer version and input.
Already-compressed or very small blobs may be stored uncompressed.

## Indexes

Required indexes:

- sequence to event location;
- time range to event-chunk range;
- event identifier to sequence;
- entity identifier to sorted event sequences;
- path entity to ordered mutations;
- span identifier to event range;
- blob digest to blob location.

Full-text search is a derived index and can be omitted or rebuilt. Index entries
contain identifiers and offsets, never process pointers.

## Snapshots

A replay snapshot records a set of path-to-content-hash mappings at an event
sequence. The first snapshot represents the verified baseline when one exists.
Later snapshots are emitted according to the replay policy.

Snapshots reuse content-addressed blobs. They do not duplicate file bytes.

## Directory and footer

The directory lists every chunk with kind, version, flags, offset, sizes,
record count, and sequence range. It is sorted by kind and ordinal.

The footer contains:

- magic `NORNEND!`;
- major and minor version;
- directory offset and size;
- total file size;
- SHA-256 digest of every preceding byte;
- completion marker;
- footer checksum.

The writer flushes file data, writes the footer, flushes again, then patches the
header offsets and checksum. Import writes to `<destination>.tmp` and atomically
renames only after reopening and validating the finished file.

## Compatibility

- A major version change may alter existing semantics or layout.
- A minor version may add optional chunks, columns, enum values, or metadata.
- Readers accept newer minor versions when every unknown addition is optional.
- Writers emit one selected version and never vary layout by host architecture.
- Unknown enum values are represented numerically and preserved.
- Derived chunks declare the analysis algorithm version that created them.
- A reader may discard incompatible derived chunks and rebuild them.

## Resource limits

Before allocation, readers enforce configurable ceilings for:

- file size;
- decoded chunk size;
- string length and total string bytes;
- blob size and total decoded blob cache;
- event, entity, span, edge, and mutation counts;
- nesting depth;
- compression ratio;
- index fan-out.

The defaults should accommodate the reference million-event stress fixture
without allowing a tiny malicious file to request unbounded memory.

## Validation modes

`norn validate trace.norn` supports:

- `quick`: header, footer, directory, bounds, and chunk checksums;
- `full`: quick checks plus all blob hashes and semantic invariants;
- `replay`: full checks plus reconstruction of every mutation chain.
