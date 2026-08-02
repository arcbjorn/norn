package model

import "core:hash"
import "core:strings"

// String interning.
//
// docs/04-trace-format.md: strings are deduplicated by exact UTF-8 bytes and
// identifier zero is the empty or absent string. The writer normalizes neither
// case nor Unicode — two strings that differ by a byte are two strings, because
// the trace is evidence and folding them would assert an equivalence the source
// never stated. Paths are normalized before interning, by the importer.

// String_Table interns strings and assigns stable identifiers in first-use
// order. That order is what makes the output deterministic: the same source
// processed twice interns in the same order and produces the same identifiers.
String_Table :: struct {
	// bytes holds every interned string concatenated. Individual strings are
	// slices into this buffer, so interning does not allocate per string.
	bytes: [dynamic]u8,
	// offsets has count+1 entries; string i spans offsets[i]..offsets[i+1].
	offsets: [dynamic]u32,

	// buckets maps a content hash to the identifiers that hash to it.
	//
	// The map deliberately does not key on the string content: a key that
	// pointed into `bytes` would dangle as soon as an append grew that buffer,
	// and a key that owned a copy would double the memory the table exists to
	// avoid. Identifiers stay valid across growth, so candidates are resolved
	// through string_get and compared by bytes.
	buckets: map[u64][dynamic]String_Id,
}

// string_table_init prepares an empty table. Identifier zero is reserved for
// the empty string and is present in every table without being interned.
string_table_init :: proc(table: ^String_Table, allocator := context.allocator) {
	table.bytes = make([dynamic]u8, 0, 4096, allocator)
	table.offsets = make([dynamic]u32, 0, 256, allocator)
	table.buckets = make(map[u64][dynamic]String_Id, 256, allocator)

	// Slot 0: the empty string. Recording its bounds keeps string_get free of
	// a special case.
	append(&table.offsets, u32(0))
	append(&table.offsets, u32(0))
}

// string_table_destroy releases the table's memory. Every string previously
// returned by string_get becomes invalid.
string_table_destroy :: proc(table: ^String_Table) {
	for _, bucket in table.buckets {
		delete(bucket)
	}
	delete(table.buckets)
	delete(table.bytes)
	delete(table.offsets)
	table^ = {}
}

// string_table_count returns the number of interned strings, including the
// reserved empty string at identifier zero.
string_table_count :: proc(table: ^String_Table) -> int {
	return len(table.offsets) - 1
}

@(private)
string_hash :: proc "contextless" (value: string) -> u64 {
	return hash.fnv64a(transmute([]byte)value)
}

// string_intern returns the identifier for `value`, interning it if new.
//
// The returned identifier is stable for the life of the table. `value` is
// copied into the table's own storage, so the caller may free it afterwards.
//
// `ok` is false only when the table would exceed the addressable identifier
// space or the total byte budget, which callers must treat as a limit failure
// rather than silently dropping the string.
string_intern :: proc(
	table: ^String_Table,
	value: string,
	max_total_bytes := u64(max(u32)),
) -> (
	id: String_Id,
	ok: bool,
) {
	if len(value) == 0 {
		return EMPTY_STRING, true
	}

	key := string_hash(value)
	if bucket, found := table.buckets[key]; found {
		for candidate in bucket {
			existing, got := string_get(table, candidate)
			if got && existing == value {
				return candidate, true
			}
		}
	}

	next_id := len(table.offsets) - 1
	if next_id > int(max(u32)) {
		return EMPTY_STRING, false
	}
	end := u64(len(table.bytes)) + u64(len(value))
	if end > max_total_bytes || end > u64(max(u32)) {
		return EMPTY_STRING, false
	}

	append(&table.bytes, value)
	append(&table.offsets, u32(len(table.bytes)))
	id = String_Id(next_id)

	bucket, found := &table.buckets[key]
	if !found {
		table.buckets[key] = make([dynamic]String_Id, 0, 2)
		bucket = &table.buckets[key]
	}
	append(bucket, id)
	return id, true
}

// string_get returns the interned string for an identifier.
//
// The result borrows the table's storage and is invalidated by a later
// string_intern that grows the buffer, or by string_table_destroy. Callers
// that must outlive either event copy the value with string_clone.
//
// An out-of-range identifier returns the empty string and false. The codec
// validates identifiers against the table when reading a trace, so a false
// result here indicates a caller bug rather than a corrupt file.
string_get :: proc(table: ^String_Table, id: String_Id) -> (value: string, ok: bool) {
	index := int(id)
	if index < 0 || index + 1 >= len(table.offsets) {
		return "", false
	}
	start := int(table.offsets[index])
	end := int(table.offsets[index + 1])
	if start > end || end > len(table.bytes) {
		return "", false
	}
	return string(table.bytes[start:end]), true
}

// string_table_reindex rebuilds the content index after a table has been
// populated directly from decoded chunk bytes, which bypasses string_intern.
//
// It also validates that offsets start at zero, never decrease, and stay in
// bounds, so a corrupt strings chunk is rejected here rather than producing
// wild slices at every later lookup.
string_table_reindex :: proc(table: ^String_Table) -> bool {
	for _, bucket in table.buckets {
		delete(bucket)
	}
	clear(&table.buckets)

	if len(table.offsets) == 0 || table.offsets[0] != 0 {
		return false
	}

	for index in 0 ..< len(table.offsets) - 1 {
		start := int(table.offsets[index])
		end := int(table.offsets[index + 1])
		if start > end || end > len(table.bytes) {
			return false
		}
		if index == 0 {
			continue // The reserved empty string is never indexed.
		}
		value := string(table.bytes[start:end])
		key := string_hash(value)
		bucket, found := &table.buckets[key]
		if !found {
			table.buckets[key] = make([dynamic]String_Id, 0, 2)
			bucket = &table.buckets[key]
		}
		append(bucket, String_Id(index))
	}
	return true
}

// string_clone copies an interned string with an explicit allocator, for
// callers that need it to outlive the table.
string_clone :: proc(value: string, allocator := context.allocator) -> string {
	return strings.clone(value, allocator)
}
