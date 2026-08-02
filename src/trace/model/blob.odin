package model

import "core:crypto/hash"

// Content-addressed blobs.
//
// docs/04-trace-format.md: large text, raw records, patches, command output,
// and file content are blobs identified by the SHA-256 of their uncompressed
// content. Duplicate content is stored once — an agent that reads the same
// file forty times produces one blob.
//
// The digest is what makes replay verifiable: docs/06 requires the reader to
// verify a digest after decompression before treating content as
// replay-verified, so the hash is the trust boundary, not an optimization.

// digest_content computes the stable content identity of a blob.
digest_content :: proc(content: []byte) -> Blob_Digest {
	result: Blob_Digest
	hash.hash(.SHA256, content, result[:])
	return result
}

// digest_equal compares two digests.
digest_equal :: proc "contextless" (a, b: Blob_Digest) -> bool {
	for index in 0 ..< len(a) {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

// digest_is_zero reports whether a digest slot is unset. A real SHA-256 of any
// input is astronomically unlikely to be all zeroes, so this doubles as an
// "absent hash" test for optional before/after hashes.
digest_is_zero :: proc "contextless" (value: Blob_Digest) -> bool {
	for b in value {
		if b != 0 {
			return false
		}
	}
	return true
}

@(private)
HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

// digest_to_hex writes the lowercase hex form into `buffer`, which must hold
// at least 64 bytes, and returns the written slice. Logs use a prefix of this;
// docs/10 permits hash prefixes in diagnostics where full content is forbidden.
digest_to_hex :: proc "contextless" (value: Blob_Digest, buffer: []byte) -> string {
	assert_contextless(len(buffer) >= 64)
	for b, index in value {
		buffer[index * 2] = HEX_DIGITS[b >> 4]
		buffer[index * 2 + 1] = HEX_DIGITS[b & 0x0F]
	}
	return string(buffer[:64])
}

// Blob_Flag marks properties a viewer must communicate rather than hide.
Blob_Flag :: enum u8 {
	// Content had secrets replaced during import. docs/08: redaction happens
	// before the content reaches the writer, so the digest is of the redacted
	// bytes, not the original.
	Redacted = 0,
	// Content was cut short by a retention limit. A diff over truncated
	// content is not a complete diff and must be labeled.
	Truncated = 1,
	// Content was produced by Norn rather than recorded by the provider.
	Derived = 2,
	// Content is a retained raw provider record. docs/10: opt-in only.
	Raw_Record = 3,
}

Blob_Flags :: bit_set[Blob_Flag; u8]

// Blob_Entry is the table row describing one stored content value. It holds
// metadata only; bytes live in blob chunks and are loaded on demand, so a
// trace can list a gigabyte of file content without reading any of it.
Blob_Entry :: struct {
	digest:      Blob_Digest,
	media_type:  String_Id,
	encoding:    Text_Encoding,
	flags:       Blob_Flags,
	// Uncompressed size in bytes. Independent of how the chunk stored it.
	size:        u64,
	// Location within the blob chunk region.
	chunk_ordinal: u32,
	chunk_offset:  u64,
	stored_size:   u64, // Bytes occupied after this blob's own compression.
}

// Blob_Table indexes blob entries by digest so that interning the same content
// twice yields one entry.
//
// `content` holds the bytes of blobs added through blob_add during import. It
// is empty for a table decoded from a trace: there, bytes stay in the mapped
// blob chunks and are fetched on demand, because a session can reference far
// more file content than a viewer should hold resident.
Blob_Table :: struct {
	entries: [dynamic]Blob_Entry,
	// lookup keys on the digest itself, which is a fixed-size array and
	// therefore safe to use as a map key: unlike an interned string, it does
	// not point into a buffer that later reallocates.
	lookup: map[Blob_Digest]Blob_Id,

	// Concatenated content for blobs added during import, indexed by the
	// entry's chunk_offset. Owned by the table.
	content: [dynamic]u8,
	// True when `content` holds the bytes for every entry, which is the case
	// for a table being built by an importer and false for one read back from
	// a trace.
	content_resident: bool,
}

// blob_table_init prepares an empty table. Identifier zero is reserved for
// "no blob" and holds a zeroed entry that is never returned by lookup.
blob_table_init :: proc(table: ^Blob_Table, allocator := context.allocator) {
	table.entries = make([dynamic]Blob_Entry, 0, 64, allocator)
	table.lookup = make(map[Blob_Digest]Blob_Id, 64, allocator)
	table.content = make([dynamic]u8, 0, 4096, allocator)
	table.content_resident = true
	append(&table.entries, Blob_Entry{})
}

// blob_table_destroy releases the table's memory.
blob_table_destroy :: proc(table: ^Blob_Table) {
	delete(table.entries)
	delete(table.lookup)
	delete(table.content)
	table^ = {}
}

// blob_add hashes `content`, stores it, and returns its identifier.
//
// This is the interning path importers use: it computes the digest, so callers
// cannot accidentally register content under a hash of different bytes. Adding
// content that is already present returns the existing identifier without
// storing a second copy.
blob_add :: proc(
	table: ^Blob_Table,
	content: []byte,
	media_type: String_Id = EMPTY_STRING,
	encoding: Text_Encoding = .Utf8,
	flags: Blob_Flags = {},
	max_count := u64(max(u32)),
) -> (
	id: Blob_Id,
	ok: bool,
) {
	digest := digest_content(content)
	if existing, found := table.lookup[digest]; found {
		return existing, true
	}

	offset := u64(len(table.content))
	append(&table.content, ..content)

	return blob_intern(
		table,
		Blob_Entry {
			digest = digest,
			media_type = media_type,
			encoding = encoding,
			flags = flags,
			size = u64(len(content)),
			chunk_offset = offset,
			stored_size = u64(len(content)),
		},
		max_count,
	)
}

// blob_content returns the bytes for a blob whose content is resident.
//
// The result borrows the table's storage. It returns false when the identifier
// is unknown or when the table was decoded from a trace, where content lives
// in mapped chunks and must be fetched through the codec instead. Returning
// false rather than empty bytes matters: empty content is a legitimate file
// state, and confusing it with "not loaded" would let replay report a file as
// emptied when it was merely unread.
blob_content :: proc(table: ^Blob_Table, id: Blob_Id) -> (content: []byte, ok: bool) {
	entry := blob_get(table, id) or_return
	if !table.content_resident {
		return nil, false
	}
	start, start_ok := checked_index(entry.chunk_offset)
	length, length_ok := checked_index(entry.size)
	if !start_ok || !length_ok || start + length > len(table.content) {
		return nil, false
	}
	return table.content[start:start + length], true
}

@(private)
checked_index :: proc "contextless" (value: u64) -> (result: int, ok: bool) {
	if value > u64(max(int)) {
		return 0, false
	}
	return int(value), true
}

// blob_table_count returns the number of real blobs, excluding the reserved
// zero slot.
blob_table_count :: proc(table: ^Blob_Table) -> int {
	return len(table.entries) - 1
}

// blob_find returns the identifier already assigned to a digest.
blob_find :: proc(table: ^Blob_Table, digest: Blob_Digest) -> (id: Blob_Id, found: bool) {
	id, found = table.lookup[digest]
	return
}

// blob_intern records an entry for `digest`, returning the existing identifier
// when the content is already known.
//
// The caller is responsible for having computed `digest` from the same bytes
// it stores; blob_intern does not hash, because the writer hashes once while
// streaming and would otherwise hash twice.
//
// `ok` is false when the table would exceed the identifier space or the
// caller-supplied blob-count ceiling.
blob_intern :: proc(
	table: ^Blob_Table,
	entry: Blob_Entry,
	max_count := u64(max(u32)),
) -> (
	id: Blob_Id,
	ok: bool,
) {
	if existing, found := table.lookup[entry.digest]; found {
		return existing, true
	}
	next := len(table.entries)
	if u64(next) > max_count || next > int(max(u32)) {
		return NO_BLOB, false
	}
	append(&table.entries, entry)
	id = Blob_Id(next)
	table.lookup[entry.digest] = id
	return id, true
}

// blob_get returns the entry for an identifier. An out-of-range identifier or
// the reserved zero identifier returns false.
blob_get :: proc(table: ^Blob_Table, id: Blob_Id) -> (entry: Blob_Entry, ok: bool) {
	index := int(id)
	if index <= 0 || index >= len(table.entries) {
		return {}, false
	}
	return table.entries[index], true
}

// blob_table_reindex rebuilds the digest map after entries have been loaded
// directly from a decoded chunk. A duplicate digest means the writer failed to
// deduplicate, which is an invariant violation the caller reports.
blob_table_reindex :: proc(table: ^Blob_Table) -> (ok: bool) {
	clear(&table.lookup)
	ok = true
	for index in 1 ..< len(table.entries) {
		digest := table.entries[index].digest
		if _, exists := table.lookup[digest]; exists {
			ok = false
			continue
		}
		table.lookup[digest] = Blob_Id(index)
	}
	return ok
}
