package codec

import "src:core"

// The .norn container format.
//
// docs/04-trace-format.md is normative for every constant and layout in this
// file. Byte conventions: little-endian integers, 64-bit offsets from the
// start of the file, signed 64-bit nanosecond timestamps, chunks aligned to
// 64-byte boundaries, reserved fields zero on write and ignored on read.

// FILE_MAGIC identifies a Norn trace.
FILE_MAGIC :: [8]u8{'N', 'O', 'R', 'N', 'T', 'R', 'C', 'E'}

// FOOTER_MAGIC marks a finalized file.
FOOTER_MAGIC :: [8]u8{'N', 'O', 'R', 'N', 'E', 'N', 'D', '!'}

// CHUNK_MAGIC begins every chunk header.
CHUNK_MAGIC :: [4]u8{'N', 'R', 'C', 'K'}

// Format version written by this build. A major change may alter existing
// semantics or layout; a minor version may add optional chunks, columns, enum
// values, or metadata.
FORMAT_MAJOR :: u16(1)
FORMAT_MINOR :: u16(0)

// The oldest major version this reader accepts.
MIN_SUPPORTED_MAJOR :: u16(1)

FILE_HEADER_SIZE  :: 64
CHUNK_HEADER_SIZE :: 64

// The footer is 96 bytes rather than 64: docs/04 requires it to carry a
// SHA-256 digest of every preceding byte, and 32 bytes of digest do not fit
// alongside the magic, versions, offsets, sizes, and completion marker. The
// footer is the last structure in the file and is located by an explicit
// offset, so its size is free to differ from the two 64-byte headers.
FOOTER_SIZE :: 96

// Offsets of the self-referential checksum field in each fixed-size header.
// The checksum is computed over the structure with these four bytes zeroed,
// so the writer and reader must agree on exactly where they are.
FILE_HEADER_CRC_OFFSET  :: 56
CHUNK_HEADER_CRC_OFFSET :: 60
FOOTER_CRC_OFFSET       :: 72

// CHUNK_ALIGNMENT is the boundary every chunk header starts on.
CHUNK_ALIGNMENT :: u64(64)

// Header_Flag records file-wide properties that a reader must know before it
// interprets any chunk.
Header_Flag :: enum u32 {
	// The file was finalized: directory and footer offsets are valid and the
	// footer digest covers the file. A reader must refuse to open a trace
	// without this, per docs/04.
	Finalized = 0,
	// Raw provider records were retained. docs/10 makes this opt-in.
	Has_Raw_Records = 1,
	// Derived chunks are present and may be discarded and rebuilt.
	Has_Derived = 2,
}

Header_Flags :: bit_set[Header_Flag; u32]

// File_Header is the 64-byte prefix of every trace. Field order and widths
// follow the table in docs/04.
//
// The struct is read and written field by field rather than memory-mapped as a
// C layout, so that byte order and padding stay explicit and identical on
// every host architecture.
File_Header :: struct {
	magic:            [8]u8,
	major:            u16,
	minor:            u16,
	flags:            Header_Flags,
	session_id:       [16]u8,
	created_unix_ns:  i64,
	directory_offset: u64,
	footer_offset:    u64,
	header_crc32c:    u32,
	// 4 reserved bytes follow, zero on write.
}

// Chunk_Kind enumerates chunk contents. docs/04 fixes the core set. Values are
// on-disk and are appended, never renumbered.
//
// A reader that meets an unknown kind consults Chunk_Flag.Optional: unknown
// optional kinds are skipped and preserved by copy-based tooling, while an
// unknown required kind is a clear unsupported-format error.
Chunk_Kind :: enum u16 {
	Invalid   = 0,
	Metadata  = 1,
	Strings   = 2,
	Entities  = 3,
	Spans     = 4,
	Events    = 5,
	Payloads  = 6,
	Edges     = 7,
	Blobs     = 8,
	Snapshots = 9,
	Derived   = 10,
	Indexes   = 11,
	Directory = 12,
	Footer    = 13,
	// Concatenated blob bytes. Separate from `Blobs`, which holds only the
	// table rows, so a reader can inspect what content exists without loading
	// it.
	Blob_Content = 14,
	// Canonical file mutations. These are recorded evidence, not derived data,
	// so the kind is required: a reader that skipped them would show a session
	// with no repository changes rather than reporting that it cannot.
	Mutations = 15,
	// Baseline manifest: the repository content observed before the session
	// began. docs/06 requires it to record only paths whose content or absence
	// was actually verified, so it is a recorded observation rather than
	// derived data, and a reader that skipped it would replay from nothing and
	// report gaps for files it could have reconstructed.
	Baseline = 16,
}

// chunk_kind_name returns a stable identifier for CLI output and tests.
chunk_kind_name :: proc "contextless" (kind: Chunk_Kind) -> string {
	switch kind {
	case .Invalid:   return "invalid"
	case .Metadata:  return "metadata"
	case .Strings:   return "strings"
	case .Entities:  return "entities"
	case .Spans:     return "spans"
	case .Events:    return "events"
	case .Payloads:  return "payloads"
	case .Edges:     return "edges"
	case .Blobs:     return "blobs"
	case .Snapshots: return "snapshots"
	case .Derived:   return "derived"
	case .Indexes:   return "indexes"
	case .Directory:    return "directory"
	case .Footer:       return "footer"
	case .Blob_Content: return "blob_content"
	case .Mutations:    return "mutations"
	case .Baseline:     return "baseline"
	}
	return "unknown"
}

// is_required_kind reports whether a reader must understand a kind to open the
// trace correctly. Derived, index, and snapshot chunks are rebuildable, so a
// reader may ignore ones it does not recognize.
is_required_kind :: proc "contextless" (kind: Chunk_Kind) -> bool {
	#partial switch kind {
	case .Snapshots, .Derived, .Indexes:
		return false
	}
	return true
}

// Chunk_Flag records per-chunk properties.
Chunk_Flag :: enum u32 {
	// The chunk may be skipped by a reader that does not understand its kind
	// or schema version.
	Optional = 0,
	// Payload bytes are compressed with the codec in `codec_id`.
	Compressed = 1,
}

Chunk_Flags :: bit_set[Chunk_Flag; u32]

// Compression_Codec identifies how a chunk payload is stored.
//
// docs/04: version one selects a single fast, bounded-memory codec during the
// phase-zero spike, and `none` is always supported. Until that spike measures
// candidates, the writer emits None; the field exists so that adding a codec
// later is a minor-version change rather than a layout change.
Compression_Codec :: enum u16 {
	None = 0,
}

// Chunk_Header is the fixed 64-byte prefix of every chunk.
//
// `first_sequence` and `last_sequence` are zero for chunks that hold no
// events, which lets a time-range query skip whole chunks without decoding
// them.
Chunk_Header :: struct {
	magic:          [4]u8,
	kind:           Chunk_Kind,
	schema_version: u16,
	flags:          Chunk_Flags,
	codec_id:       Compression_Codec,
	ordinal:        u32,
	record_count:   u32,
	encoded_size:   u64,
	decoded_size:   u64,
	first_sequence: u64,
	last_sequence:  u64,
	payload_crc32c: u32,
	header_crc32c:  u32,
}

// SCHEMA_VERSION is the payload schema this build writes for each kind.
// Bumping one of these is a minor-version change when readers can skip or
// tolerate the difference.
SCHEMA_METADATA  :: u16(1)
SCHEMA_STRINGS   :: u16(1)
SCHEMA_ENTITIES  :: u16(1)
SCHEMA_SPANS     :: u16(1)
SCHEMA_EVENTS    :: u16(1)
SCHEMA_EDGES     :: u16(1)
SCHEMA_BLOBS        :: u16(1)
SCHEMA_BLOB_CONTENT :: u16(1)
SCHEMA_MUTATIONS    :: u16(1)
SCHEMA_PAYLOADS     :: u16(1)
SCHEMA_DIRECTORY    :: u16(1)
SCHEMA_BASELINE     :: u16(1)

// Directory_Entry locates one chunk. The directory is sorted by kind then
// ordinal, and readers locate chunks through it rather than assuming physical
// order.
Directory_Entry :: struct {
	kind:           Chunk_Kind,
	schema_version: u16,
	flags:          Chunk_Flags,
	ordinal:        u32,
	record_count:   u32,
	offset:         u64, // Offset of the chunk header, not its payload.
	encoded_size:   u64,
	decoded_size:   u64,
	first_sequence: u64,
	last_sequence:  u64,
}

DIRECTORY_ENTRY_SIZE :: 64

// Footer marks a complete file and carries the digest of everything before it.
Footer :: struct {
	magic:          [8]u8,
	major:          u16,
	minor:          u16,
	directory_offset: u64,
	directory_size:   u64,
	total_size:       u64,
	// SHA-256 of every byte preceding the footer.
	digest: [32]u8,
	// Completion marker, distinct from the header flag so a truncated write
	// cannot leave a file that claims completeness in only one place.
	complete: u32,
	footer_crc32c: u32,
}

// FOOTER_COMPLETE is the value written to Footer.complete on a finalized file.
FOOTER_COMPLETE :: u32(0x4E4F524E) // "NORN"

// Byte cursor helpers.
//
// All container fields are written and read through these so that byte order
// is explicit at every field, and so that a read can never run past the end of
// the buffer it was given.

Reader_Cursor :: struct {
	data:   []byte,
	offset: int,
}

// read_u8 through read_bytes return false when the buffer is exhausted, which
// the caller reports as truncated input rather than treating as a zero value.

@(require_results)
read_u8 :: proc "contextless" (cursor: ^Reader_Cursor) -> (value: u8, ok: bool) {
	if cursor.offset + 1 > len(cursor.data) {
		return 0, false
	}
	value = cursor.data[cursor.offset]
	cursor.offset += 1
	return value, true
}

@(require_results)
read_u16 :: proc "contextless" (cursor: ^Reader_Cursor) -> (value: u16, ok: bool) {
	if cursor.offset + 2 > len(cursor.data) {
		return 0, false
	}
	b := cursor.data[cursor.offset:]
	value = u16(b[0]) | u16(b[1]) << 8
	cursor.offset += 2
	return value, true
}

@(require_results)
read_u32 :: proc "contextless" (cursor: ^Reader_Cursor) -> (value: u32, ok: bool) {
	if cursor.offset + 4 > len(cursor.data) {
		return 0, false
	}
	b := cursor.data[cursor.offset:]
	value = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	cursor.offset += 4
	return value, true
}

@(require_results)
read_u64 :: proc "contextless" (cursor: ^Reader_Cursor) -> (value: u64, ok: bool) {
	if cursor.offset + 8 > len(cursor.data) {
		return 0, false
	}
	b := cursor.data[cursor.offset:]
	value =
		u64(b[0]) |
		u64(b[1]) << 8 |
		u64(b[2]) << 16 |
		u64(b[3]) << 24 |
		u64(b[4]) << 32 |
		u64(b[5]) << 40 |
		u64(b[6]) << 48 |
		u64(b[7]) << 56
	cursor.offset += 8
	return value, true
}

@(require_results)
read_i64 :: proc "contextless" (cursor: ^Reader_Cursor) -> (value: i64, ok: bool) {
	raw := read_u64(cursor) or_return
	return i64(raw), true
}

@(require_results)
read_bytes :: proc "contextless" (cursor: ^Reader_Cursor, count: int) -> (value: []byte, ok: bool) {
	if count < 0 || cursor.offset + count > len(cursor.data) {
		return nil, false
	}
	value = cursor.data[cursor.offset:cursor.offset + count]
	cursor.offset += count
	return value, true
}

// skip advances the cursor without reading, used for reserved fields.
@(require_results)
skip :: proc "contextless" (cursor: ^Reader_Cursor, count: int) -> bool {
	if count < 0 || cursor.offset + count > len(cursor.data) {
		return false
	}
	cursor.offset += count
	return true
}

Writer_Cursor :: struct {
	data:   ^[dynamic]u8,
}

write_u8 :: proc(cursor: ^Writer_Cursor, value: u8) {
	append(cursor.data, value)
}

write_u16 :: proc(cursor: ^Writer_Cursor, value: u16) {
	append(cursor.data, u8(value), u8(value >> 8))
}

write_u32 :: proc(cursor: ^Writer_Cursor, value: u32) {
	append(cursor.data, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

write_u64 :: proc(cursor: ^Writer_Cursor, value: u64) {
	append(
		cursor.data,
		u8(value),
		u8(value >> 8),
		u8(value >> 16),
		u8(value >> 24),
		u8(value >> 32),
		u8(value >> 40),
		u8(value >> 48),
		u8(value >> 56),
	)
}

write_i64 :: proc(cursor: ^Writer_Cursor, value: i64) {
	write_u64(cursor, u64(value))
}

write_bytes :: proc(cursor: ^Writer_Cursor, value: []byte) {
	append(cursor.data, ..value)
}

// write_zeros emits `count` reserved bytes.
write_zeros :: proc(cursor: ^Writer_Cursor, count: int) {
	for _ in 0 ..< count {
		append(cursor.data, u8(0))
	}
}

// pad_to_alignment appends zero bytes until the buffer length is a multiple of
// CHUNK_ALIGNMENT, so the next chunk header starts on a 64-byte boundary.
pad_to_alignment :: proc(buffer: ^[dynamic]u8) -> bool {
	current := u64(len(buffer))
	target, ok := core.align_up(current, CHUNK_ALIGNMENT)
	if !ok {
		return false
	}
	for _ in current ..< target {
		append(buffer, u8(0))
	}
	return true
}
