package codec

import "src:core"
import "src:trace/model"

// Chunk payload encoding and decoding.
//
// docs/04-trace-format.md: high-cardinality fixed-width fields use
// structure-of-arrays encoding inside a chunk, so that time and kind filtering
// touch fewer bytes and the renderer can copy selected columns efficiently.
//
// Each decoder validates that its declared counts and offsets stay inside the
// decoded chunk before it reads a single record.

// EVENTS_PER_CHUNK bounds how many event rows one chunk holds. Smaller chunks
// let a time-range query skip more precisely; larger chunks reduce per-chunk
// overhead. This value is tunable after the phase-zero measurements.
EVENTS_PER_CHUNK :: 8192

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

// encode_strings writes a strings chunk payload: count, count+1 offsets, then
// concatenated UTF-8 bytes.
//
// The reserved empty string at identifier zero is included in the offset array
// so that a reader reconstructs the table with the same identifiers the writer
// assigned, without a special case.
encode_strings :: proc(buffer: ^[dynamic]u8, table: ^model.String_Table) {
	cursor := Writer_Cursor{data = buffer}
	count := u32(model.string_table_count(table))
	write_u32(&cursor, count)
	write_u32(&cursor, u32(len(table.bytes)))
	for offset in table.offsets {
		write_u32(&cursor, offset)
	}
	write_bytes(&cursor, table.bytes[:])
}

// decode_strings reconstructs a string table from a chunk payload.
//
// The table takes ownership of freshly allocated storage; the payload is only
// read. This copy is deliberate: the string table outlives any single chunk
// lease, and holding slices into a mapping would make every string a dangling
// pointer once the mapping closed.
decode_strings :: proc(
	payload: []byte,
	table: ^model.String_Table,
	limits := core.DEFAULT_LIMITS,
	allocator := context.allocator,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}

	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "strings chunk is missing its count")
	}
	byte_length: u32
	byte_length, ok = read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "strings chunk is missing its byte length")
	}

	if err := core.check_limit(
		u64(count),
		limits.max_string_count,
		"strings chunk exceeds the string-count limit",
	); !core.ok(err) {
		return err
	}
	if err := core.check_limit(
		u64(byte_length),
		limits.max_total_string_bytes,
		"strings chunk exceeds the total string-byte limit",
	); !core.ok(err) {
		return err
	}

	// offsets holds count+1 entries; the count includes the reserved empty
	// string, so the array has count+1 elements for identifiers 0..count.
	offset_count := u64(count) + 1
	offset_bytes, mul_ok := core.mul_u64(offset_count, 4)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "strings offset array size overflows")
	}
	needed, sum_ok := core.add_u64(offset_bytes, u64(byte_length))
	if !sum_ok {
		return core.err_make(.Limit_Exceeded, "strings chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), needed, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "strings chunk is shorter than it declares")
	}

	model.string_table_init(table, allocator)

	clear(&table.offsets)
	for _ in 0 ..< offset_count {
		value, got := read_u32(&cursor)
		if !got {
			model.string_table_destroy(table)
			return core.err_make(.Truncated_Input, "strings offset array is truncated")
		}
		append(&table.offsets, value)
	}

	raw, got := read_bytes(&cursor, int(byte_length))
	if !got {
		model.string_table_destroy(table)
		return core.err_make(.Truncated_Input, "strings byte block is truncated")
	}
	clear(&table.bytes)
	append(&table.bytes, ..raw)

	// reindex validates that offsets start at zero, never decrease, and stay
	// in bounds. A corrupt table is rejected here rather than producing wild
	// slices at every later lookup.
	if !model.string_table_reindex(table) {
		model.string_table_destroy(table)
		return core.err_make(.Malformed_Container, "strings chunk has invalid offsets")
	}
	return nil
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

// EVENT_COLUMNS is the number of columns an events chunk stores. It is written
// into the payload so a reader can reject a chunk whose column count does not
// match the schema version it claims.
EVENT_COLUMNS :: 15

// encode_events writes an events chunk payload in structure-of-arrays order.
//
// Column order is fixed by the schema version. Appending an optional column is
// a minor-version change; reordering is not.
encode_events :: proc(buffer: ^[dynamic]u8, events: []model.Event) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(events)))
	write_u32(&cursor, u32(EVENT_COLUMNS))

	for event in events { write_u64(&cursor, u64(event.id)) }
	for event in events { write_u64(&cursor, u64(event.sequence)) }
	for event in events { write_u16(&cursor, u16(event.kind)) }
	for event in events { write_u8(&cursor, transmute(u8)event.flags) }
	for event in events { write_u8(&cursor, u8(event.time_quality)) }
	for event in events { write_i64(&cursor, event.wall_time_ns) }
	for event in events { write_i64(&cursor, event.monotonic_offset_ns) }
	for event in events { write_i64(&cursor, event.duration_ns) }
	for event in events { write_u64(&cursor, u64(event.parent_span_id)) }
	for event in events { write_u64(&cursor, u64(event.actor_entity_id)) }
	for event in events { write_u64(&cursor, u64(event.primary_entity_id)) }
	for event in events { write_u32(&cursor, u32(event.summary_string_id)) }
	for event in events { write_u16(&cursor, event.payload.group) }
	for event in events { write_u32(&cursor, event.payload.index) }

	// Source provenance travels with the event, per docs/03.
	for event in events {
		write_u32(&cursor, u32(event.source.importer_id))
		write_u32(&cursor, u32(event.source.importer_version))
		write_u32(&cursor, u32(event.source.source_file))
		write_u32(&cursor, u32(event.source.source_type))
		write_u64(&cursor, event.source.record_number)
		write_u64(&cursor, event.source.byte_offset)
		write_u32(&cursor, u32(event.source.raw_blob))
		write_u8(&cursor, transmute(u8)event.source.transforms)
		write_zeros(&cursor, 3) // Reserved, keeps the row 8-byte aligned.
	}
}

// EVENT_SOURCE_ROW_SIZE is the fixed width of one source-provenance row.
EVENT_SOURCE_ROW_SIZE :: 40

// decode_events reconstructs events from a chunk payload into `out`, which is
// appended to. Every column's extent is checked against the payload before any
// element is read.
decode_events :: proc(
	payload: []byte,
	out: ^[dynamic]model.Event,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}

	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "events chunk is missing its count")
	}
	columns: u32
	columns, ok = read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "events chunk is missing its column count")
	}
	if columns != EVENT_COLUMNS {
		return core.err_make(
			.Unsupported_Feature,
			"events chunk declares an unexpected column count",
		)
	}
	if err := core.check_limit(
		u64(count),
		limits.max_event_count,
		"events chunk exceeds the event-count limit",
	); !core.ok(err) {
		return err
	}

	// Sum every column's byte extent before reading, so a declared count that
	// exceeds the payload is rejected once rather than per column.
	n := u64(count)
	widths := [?]u64{8, 8, 2, 1, 1, 8, 8, 8, 8, 8, 8, 4, 2, 4, EVENT_SOURCE_ROW_SIZE}
	total := u64(0)
	for width in widths {
		span, mul_ok := core.mul_u64(n, width)
		if !mul_ok {
			return core.err_make(.Limit_Exceeded, "events chunk column size overflows")
		}
		sum, sum_ok := core.add_u64(total, span)
		if !sum_ok {
			return core.err_make(.Limit_Exceeded, "events chunk size overflows")
		}
		total = sum
	}
	if !core.range_within(u64(cursor.offset), total, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "events chunk is shorter than it declares")
	}

	base := len(out^)
	resize(out, base + int(count))
	events := out[base:]

	for index in 0 ..< int(count) {
		raw, _ := read_u64(&cursor)
		events[index].id = model.Event_Id(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u64(&cursor)
		events[index].sequence = model.Sequence(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u16(&cursor)
		events[index].kind = model.Event_Kind(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u8(&cursor)
		events[index].flags = transmute(model.Event_Flags)raw
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u8(&cursor)
		events[index].time_quality = model.Time_Quality(raw)
	}
	for index in 0 ..< int(count) {
		events[index].wall_time_ns, _ = read_i64(&cursor)
	}
	for index in 0 ..< int(count) {
		events[index].monotonic_offset_ns, _ = read_i64(&cursor)
	}
	for index in 0 ..< int(count) {
		events[index].duration_ns, _ = read_i64(&cursor)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u64(&cursor)
		events[index].parent_span_id = model.Span_Id(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u64(&cursor)
		events[index].actor_entity_id = model.Entity_Id(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u64(&cursor)
		events[index].primary_entity_id = model.Entity_Id(raw)
	}
	for index in 0 ..< int(count) {
		raw, _ := read_u32(&cursor)
		events[index].summary_string_id = model.String_Id(raw)
	}
	for index in 0 ..< int(count) {
		events[index].payload.group, _ = read_u16(&cursor)
	}
	for index in 0 ..< int(count) {
		events[index].payload.index, _ = read_u32(&cursor)
	}
	for index in 0 ..< int(count) {
		source: model.Source_Ref
		raw: u32
		raw, _ = read_u32(&cursor); source.importer_id = model.String_Id(raw)
		raw, _ = read_u32(&cursor); source.importer_version = model.String_Id(raw)
		raw, _ = read_u32(&cursor); source.source_file = model.String_Id(raw)
		raw, _ = read_u32(&cursor); source.source_type = model.String_Id(raw)
		source.record_number, _ = read_u64(&cursor)
		source.byte_offset, _ = read_u64(&cursor)
		raw, _ = read_u32(&cursor); source.raw_blob = model.Blob_Id(raw)
		flags: u8
		flags, _ = read_u8(&cursor)
		source.transforms = transmute(model.Transform_Flags)flags
		if !skip(&cursor, 3) {
			return core.err_make(.Truncated_Input, "event source row is truncated")
		}
		events[index].source = source
	}

	return nil
}

// ---------------------------------------------------------------------------
// Entities
// ---------------------------------------------------------------------------

ENTITY_ROW_SIZE :: 48

encode_entities :: proc(buffer: ^[dynamic]u8, entities: []model.Entity) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(entities)))
	write_u32(&cursor, 0) // Reserved.
	for entity in entities {
		write_u64(&cursor, u64(entity.id))
		write_u16(&cursor, u16(entity.kind))
		write_zeros(&cursor, 2) // Reserved.
		write_u32(&cursor, u32(entity.name))
		write_u32(&cursor, u32(entity.qualifier))
		write_zeros(&cursor, 4) // Reserved.
		write_u64(&cursor, u64(entity.parent))
		write_u64(&cursor, u64(entity.first_seen))
		write_u64(&cursor, u64(entity.last_seen))
	}
}

decode_entities :: proc(
	payload: []byte,
	out: ^[dynamic]model.Entity,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "entities chunk is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "entities chunk header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_entity_count,
		"entities chunk exceeds the entity-count limit",
	); !core.ok(err) {
		return err
	}
	span, mul_ok := core.mul_u64(u64(count), ENTITY_ROW_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "entities chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), span, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "entities chunk is shorter than it declares")
	}

	for _ in 0 ..< int(count) {
		entity: model.Entity
		raw64: u64
		raw32: u32
		raw16: u16

		raw64, _ = read_u64(&cursor); entity.id = model.Entity_Id(raw64)
		raw16, _ = read_u16(&cursor); entity.kind = model.Entity_Kind(raw16)
		_ = skip(&cursor, 2)
		raw32, _ = read_u32(&cursor); entity.name = model.String_Id(raw32)
		raw32, _ = read_u32(&cursor); entity.qualifier = model.String_Id(raw32)
		_ = skip(&cursor, 4)
		raw64, _ = read_u64(&cursor); entity.parent = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); entity.first_seen = model.Sequence(raw64)
		raw64, _ = read_u64(&cursor); entity.last_seen = model.Sequence(raw64)

		append(out, entity)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Spans
// ---------------------------------------------------------------------------

SPAN_ROW_SIZE :: 56

encode_spans :: proc(buffer: ^[dynamic]u8, spans: []model.Span) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(spans)))
	write_u32(&cursor, 0) // Reserved.
	for span in spans {
		write_u64(&cursor, u64(span.id))
		write_u16(&cursor, u16(span.kind))
		write_u8(&cursor, transmute(u8)span.flags)
		write_zeros(&cursor, 1) // Reserved.
		write_u32(&cursor, u32(span.name))
		write_u64(&cursor, u64(span.parent))
		write_u64(&cursor, u64(span.start_sequence))
		write_u64(&cursor, u64(span.end_sequence))
		write_u64(&cursor, u64(span.start_event))
		write_u64(&cursor, u64(span.end_event))
	}
}

decode_spans :: proc(
	payload: []byte,
	out: ^[dynamic]model.Span,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "spans chunk is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "spans chunk header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_span_count,
		"spans chunk exceeds the span-count limit",
	); !core.ok(err) {
		return err
	}
	span_bytes, mul_ok := core.mul_u64(u64(count), SPAN_ROW_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "spans chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), span_bytes, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "spans chunk is shorter than it declares")
	}

	for _ in 0 ..< int(count) {
		span: model.Span
		raw64: u64
		raw32: u32
		raw16: u16
		raw8: u8

		raw64, _ = read_u64(&cursor); span.id = model.Span_Id(raw64)
		raw16, _ = read_u16(&cursor); span.kind = model.Span_Kind(raw16)
		raw8, _ = read_u8(&cursor); span.flags = transmute(model.Span_Flags)raw8
		_ = skip(&cursor, 1)
		raw32, _ = read_u32(&cursor); span.name = model.String_Id(raw32)
		raw64, _ = read_u64(&cursor); span.parent = model.Span_Id(raw64)
		raw64, _ = read_u64(&cursor); span.start_sequence = model.Sequence(raw64)
		raw64, _ = read_u64(&cursor); span.end_sequence = model.Sequence(raw64)
		raw64, _ = read_u64(&cursor); span.start_event = model.Event_Id(raw64)
		raw64, _ = read_u64(&cursor); span.end_event = model.Event_Id(raw64)

		append(out, span)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Edges
// ---------------------------------------------------------------------------

EDGE_ROW_SIZE :: 40

encode_edges :: proc(buffer: ^[dynamic]u8, edges: []model.Edge) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(edges)))
	write_u32(&cursor, 0) // Reserved.
	for edge in edges {
		write_u16(&cursor, u16(edge.kind))
		write_u8(&cursor, u8(edge.origin))
		write_u8(&cursor, u8(edge.from.kind))
		write_u8(&cursor, u8(edge.to.kind))
		write_zeros(&cursor, 3) // Reserved.
		write_u64(&cursor, edge.from.id)
		write_u64(&cursor, edge.to.id)
		write_u16(&cursor, u16(edge.confidence))
		write_zeros(&cursor, 2) // Reserved.
		write_u32(&cursor, u32(edge.rule))
		write_u32(&cursor, u32(edge.reason))
		write_zeros(&cursor, 4) // Reserved.
	}
}

decode_edges :: proc(
	payload: []byte,
	out: ^[dynamic]model.Edge,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "edges chunk is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "edges chunk header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_edge_count,
		"edges chunk exceeds the edge-count limit",
	); !core.ok(err) {
		return err
	}
	span, mul_ok := core.mul_u64(u64(count), EDGE_ROW_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "edges chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), span, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "edges chunk is shorter than it declares")
	}

	for _ in 0 ..< int(count) {
		edge: model.Edge
		raw8: u8
		raw16: u16
		raw32: u32

		raw16, _ = read_u16(&cursor); edge.kind = model.Edge_Kind(raw16)
		raw8, _ = read_u8(&cursor); edge.origin = model.Edge_Origin(raw8)
		raw8, _ = read_u8(&cursor); edge.from.kind = model.Endpoint_Kind(raw8)
		raw8, _ = read_u8(&cursor); edge.to.kind = model.Endpoint_Kind(raw8)
		_ = skip(&cursor, 3)
		edge.from.id, _ = read_u64(&cursor)
		edge.to.id, _ = read_u64(&cursor)
		raw16, _ = read_u16(&cursor); edge.confidence = model.Confidence(raw16)
		_ = skip(&cursor, 2)
		raw32, _ = read_u32(&cursor); edge.rule = model.String_Id(raw32)
		raw32, _ = read_u32(&cursor); edge.reason = model.String_Id(raw32)
		_ = skip(&cursor, 4)

		append(out, edge)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Blobs
// ---------------------------------------------------------------------------

BLOB_ROW_SIZE :: 64

encode_blobs :: proc(buffer: ^[dynamic]u8, entries: []model.Blob_Entry) {
	cursor := Writer_Cursor{data = buffer}
	// Entry zero is the reserved "no blob" slot and is not written.
	real := entries[1:] if len(entries) > 0 else entries
	write_u32(&cursor, u32(len(real)))
	write_u32(&cursor, 0) // Reserved.
	for entry in real {
		digest := entry.digest
		write_bytes(&cursor, digest[:])
		write_u32(&cursor, u32(entry.media_type))
		write_u8(&cursor, u8(entry.encoding))
		write_u8(&cursor, transmute(u8)entry.flags)
		write_zeros(&cursor, 2) // Reserved.
		write_u64(&cursor, entry.size)
		write_u32(&cursor, entry.chunk_ordinal)
		write_zeros(&cursor, 4) // Reserved.
		write_u64(&cursor, entry.chunk_offset)
	}
}

decode_blobs :: proc(
	payload: []byte,
	table: ^model.Blob_Table,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "blobs chunk is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "blobs chunk header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_blob_count,
		"blobs chunk exceeds the blob-count limit",
	); !core.ok(err) {
		return err
	}
	span, mul_ok := core.mul_u64(u64(count), BLOB_ROW_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "blobs chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), span, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "blobs chunk is shorter than it declares")
	}

	for _ in 0 ..< int(count) {
		entry: model.Blob_Entry
		raw, _ := read_bytes(&cursor, 32)
		copy(entry.digest[:], raw)

		raw32: u32
		raw8: u8
		raw32, _ = read_u32(&cursor); entry.media_type = model.String_Id(raw32)
		raw8, _ = read_u8(&cursor); entry.encoding = model.Text_Encoding(raw8)
		raw8, _ = read_u8(&cursor); entry.flags = transmute(model.Blob_Flags)raw8
		_ = skip(&cursor, 2)
		entry.size, _ = read_u64(&cursor)
		entry.chunk_ordinal, _ = read_u32(&cursor)
		_ = skip(&cursor, 4)
		entry.chunk_offset, _ = read_u64(&cursor)

		if err := core.check_limit(
			entry.size,
			limits.max_blob_size,
			"blob entry exceeds the blob-size limit",
		); !core.ok(err) {
			return err
		}

		append(&table.entries, entry)
	}

	// A duplicate digest means the writer failed to deduplicate, which
	// docs/04 forbids: duplicate content is stored once.
	if !model.blob_table_reindex(table) {
		return core.err_make(.Invariant_Violation, "blobs chunk contains duplicate digests")
	}
	return nil
}
