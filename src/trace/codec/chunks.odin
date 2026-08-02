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
// Payloads
// ---------------------------------------------------------------------------

// encode_payloads writes every typed payload group into one chunk.
//
// The groups share a chunk because they are read together: opening a trace
// loads all payload tables, and splitting them would multiply chunk overhead
// without giving any query a smaller thing to read. Each group declares its
// own count so a future minor version can append a group.
encode_payloads :: proc(buffer: ^[dynamic]u8, tables: ^model.Payload_Tables) {
	cursor := Writer_Cursor{data = buffer}

	write_u32(&cursor, u32(len(tables.diagnostics)))
	write_u32(&cursor, u32(len(tables.commands)))
	write_u32(&cursor, u32(len(tables.tests)))
	write_u32(&cursor, u32(len(tables.messages)))
	write_u32(&cursor, u32(len(tables.tools)))
	write_u32(&cursor, u32(len(tables.arguments)))

	for payload in tables.diagnostics {
		write_u8(&cursor, u8(payload.severity))
		write_zeros(&cursor, 3) // Reserved.
		write_u64(&cursor, u64(payload.path))
		write_u64(&cursor, u64(payload.symbol))
		write_u32(&cursor, payload.line)
		write_u32(&cursor, payload.column)
		write_u32(&cursor, payload.end_line)
		write_u32(&cursor, u32(payload.code))
		write_u32(&cursor, u32(payload.message))
	}

	for payload in tables.commands {
		write_u64(&cursor, u64(payload.command))
		write_u64(&cursor, u64(payload.working_directory))
		write_u32(&cursor, u32(payload.command_line))
		write_u32(&cursor, payload.argv_start)
		write_u32(&cursor, payload.argv_count)
		write_u32(&cursor, u32(payload.exit_code))
		write_u8(&cursor, u8(payload.status))
		write_u8(&cursor, payload.has_argv ? 1 : 0)
		write_zeros(&cursor, 2) // Reserved.
	}

	for payload in tables.tests {
		write_u64(&cursor, u64(payload.test_case))
		write_u64(&cursor, u64(payload.suite))
		write_u64(&cursor, u64(payload.command))
		write_u32(&cursor, u32(payload.message))
		write_u32(&cursor, payload.line)
		// path and status share the tail of the row.
		write_u64(&cursor, u64(payload.path))
		write_u8(&cursor, u8(payload.status))
		write_zeros(&cursor, 7) // Reserved.
	}

	for payload in tables.messages {
		write_u32(&cursor, u32(payload.text))
		write_u32(&cursor, u32(payload.summary))
		write_u64(&cursor, u64(payload.model))
		write_u8(&cursor, payload.goal_bearing ? 1 : 0)
		write_zeros(&cursor, 7) // Reserved.
	}

	for payload in tables.tools {
		write_u64(&cursor, u64(payload.tool))
		write_u32(&cursor, u32(payload.call_id))
		write_u32(&cursor, u32(payload.content))
		write_u32(&cursor, u32(payload.error_message))
		write_u8(&cursor, payload.structured ? 1 : 0)
		write_u8(&cursor, u8(payload.status))
		write_zeros(&cursor, 6) // Reserved.
	}

	for argument in tables.arguments {
		write_u32(&cursor, u32(argument))
	}
}

// Row widths as actually written above, so the decoder's extent check matches
// the encoder without either drifting.
@(private)
DIAGNOSTIC_ROW_STORED :: 4 + 8 + 8 + 4 + 4 + 4 + 4 + 4 // 40
@(private)
COMMAND_ROW_STORED :: 8 + 8 + 4 + 4 + 4 + 4 + 1 + 1 + 2 // 36
@(private)
TEST_ROW_STORED :: 8 + 8 + 8 + 4 + 4 + 8 + 1 + 7 // 48
@(private)
MESSAGE_ROW_STORED :: 4 + 4 + 8 + 1 + 7 // 24
@(private)
TOOL_ROW_STORED :: 8 + 4 + 4 + 4 + 1 + 1 + 6 // 28

decode_payloads :: proc(
	payload: []byte,
	tables: ^model.Payload_Tables,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}

	counts: [6]u32
	for index in 0 ..< 6 {
		value, ok := read_u32(&cursor)
		if !ok {
			return core.err_make(.Truncated_Input, "payloads chunk is missing its counts")
		}
		counts[index] = value
	}

	// Every group's extent is summed and bounds-checked before a single row is
	// read, so a declared count that exceeds the payload is rejected once.
	widths := [?]u64 {
		DIAGNOSTIC_ROW_STORED,
		COMMAND_ROW_STORED,
		TEST_ROW_STORED,
		MESSAGE_ROW_STORED,
		TOOL_ROW_STORED,
		4, // Argument entries.
	}
	total := u64(0)
	for index in 0 ..< 6 {
		if err := core.check_limit(
			u64(counts[index]),
			limits.max_event_count,
			"payloads chunk exceeds the row-count limit",
		); !core.ok(err) {
			return err
		}
		span, mul_ok := core.mul_u64(u64(counts[index]), widths[index])
		if !mul_ok {
			return core.err_make(.Limit_Exceeded, "payloads chunk group size overflows")
		}
		sum, sum_ok := core.add_u64(total, span)
		if !sum_ok {
			return core.err_make(.Limit_Exceeded, "payloads chunk size overflows")
		}
		total = sum
	}
	if !core.range_within(u64(cursor.offset), total, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "payloads chunk is shorter than it declares")
	}

	for _ in 0 ..< int(counts[0]) {
		row: model.Diagnostic_Payload
		raw8, _ := read_u8(&cursor)
		row.severity = model.Severity(raw8)
		_ = skip(&cursor, 3)
		raw64: u64
		raw32: u32
		raw64, _ = read_u64(&cursor); row.path = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); row.symbol = model.Entity_Id(raw64)
		row.line, _ = read_u32(&cursor)
		row.column, _ = read_u32(&cursor)
		row.end_line, _ = read_u32(&cursor)
		raw32, _ = read_u32(&cursor); row.code = model.String_Id(raw32)
		raw32, _ = read_u32(&cursor); row.message = model.String_Id(raw32)
		append(&tables.diagnostics, row)
	}

	for _ in 0 ..< int(counts[1]) {
		row: model.Command_Payload
		raw64: u64
		raw32: u32
		raw8: u8
		raw64, _ = read_u64(&cursor); row.command = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); row.working_directory = model.Entity_Id(raw64)
		raw32, _ = read_u32(&cursor); row.command_line = model.String_Id(raw32)
		row.argv_start, _ = read_u32(&cursor)
		row.argv_count, _ = read_u32(&cursor)
		raw32, _ = read_u32(&cursor); row.exit_code = i32(raw32)
		raw8, _ = read_u8(&cursor); row.status = model.Outcome_Status(raw8)
		raw8, _ = read_u8(&cursor); row.has_argv = raw8 != 0
		_ = skip(&cursor, 2)
		append(&tables.commands, row)
	}

	for _ in 0 ..< int(counts[2]) {
		row: model.Test_Payload
		raw64: u64
		raw32: u32
		raw8: u8
		raw64, _ = read_u64(&cursor); row.test_case = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); row.suite = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); row.command = model.Entity_Id(raw64)
		raw32, _ = read_u32(&cursor); row.message = model.String_Id(raw32)
		row.line, _ = read_u32(&cursor)
		raw64, _ = read_u64(&cursor); row.path = model.Entity_Id(raw64)
		raw8, _ = read_u8(&cursor); row.status = model.Outcome_Status(raw8)
		_ = skip(&cursor, 7)
		append(&tables.tests, row)
	}

	for _ in 0 ..< int(counts[3]) {
		row: model.Message_Payload
		raw64: u64
		raw32: u32
		raw8: u8
		raw32, _ = read_u32(&cursor); row.text = model.Blob_Id(raw32)
		raw32, _ = read_u32(&cursor); row.summary = model.String_Id(raw32)
		raw64, _ = read_u64(&cursor); row.model = model.Entity_Id(raw64)
		raw8, _ = read_u8(&cursor); row.goal_bearing = raw8 != 0
		_ = skip(&cursor, 7)
		append(&tables.messages, row)
	}

	for _ in 0 ..< int(counts[4]) {
		row: model.Tool_Payload
		raw64: u64
		raw32: u32
		raw8: u8
		raw64, _ = read_u64(&cursor); row.tool = model.Entity_Id(raw64)
		raw32, _ = read_u32(&cursor); row.call_id = model.String_Id(raw32)
		raw32, _ = read_u32(&cursor); row.content = model.Blob_Id(raw32)
		raw32, _ = read_u32(&cursor); row.error_message = model.String_Id(raw32)
		raw8, _ = read_u8(&cursor); row.structured = raw8 != 0
		raw8, _ = read_u8(&cursor); row.status = model.Outcome_Status(raw8)
		_ = skip(&cursor, 6)
		append(&tables.tools, row)
	}

	for _ in 0 ..< int(counts[5]) {
		value, _ := read_u32(&cursor)
		append(&tables.arguments, model.String_Id(value))
	}

	return nil
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

// 8 event + 8 path + 8 old_path + 4 discriminants + 4 patch + 4 content
// + 4 reserved + 32 before_hash + 32 after_hash.
MUTATION_ROW_SIZE :: 104

// encode_mutations writes the canonical file mutations.
//
// Mutations carry the before and after hashes inline rather than as blob
// references: replay compares them on every application, and a 32-byte hash is
// cheaper to read in place than to resolve through a table.
encode_mutations :: proc(buffer: ^[dynamic]u8, mutations: []model.Mutation) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(mutations)))
	write_u32(&cursor, 0) // Reserved.
	for mutation in mutations {
		before := mutation.before_hash
		after := mutation.after_hash

		write_u64(&cursor, u64(mutation.event_id))
		write_u64(&cursor, u64(mutation.path))
		write_u64(&cursor, u64(mutation.old_path))
		write_u8(&cursor, u8(mutation.op))
		write_u8(&cursor, u8(mutation.encoding))
		write_u8(&cursor, transmute(u8)mutation.flags)
		write_u8(&cursor, u8(mutation.status))
		write_u32(&cursor, u32(mutation.patch_blob))
		write_u32(&cursor, u32(mutation.content_blob))
		write_zeros(&cursor, 4) // Reserved.
		write_bytes(&cursor, before[:])
		write_bytes(&cursor, after[:])
	}
}

decode_mutations :: proc(
	payload: []byte,
	out: ^[dynamic]model.Mutation,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "mutations chunk is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "mutations chunk header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_mutation_count,
		"mutations chunk exceeds the mutation-count limit",
	); !core.ok(err) {
		return err
	}
	span, mul_ok := core.mul_u64(u64(count), MUTATION_ROW_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "mutations chunk size overflows")
	}
	if !core.range_within(u64(cursor.offset), span, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "mutations chunk is shorter than it declares")
	}

	for _ in 0 ..< int(count) {
		mutation: model.Mutation
		raw64: u64
		raw32: u32
		raw8: u8

		raw64, _ = read_u64(&cursor); mutation.event_id = model.Event_Id(raw64)
		raw64, _ = read_u64(&cursor); mutation.path = model.Entity_Id(raw64)
		raw64, _ = read_u64(&cursor); mutation.old_path = model.Entity_Id(raw64)
		raw8, _ = read_u8(&cursor); mutation.op = model.Mutation_Op(raw8)
		raw8, _ = read_u8(&cursor); mutation.encoding = model.Text_Encoding(raw8)
		raw8, _ = read_u8(&cursor); mutation.flags = transmute(model.Mutation_Flags)raw8
		raw8, _ = read_u8(&cursor); mutation.status = model.Replay_Status(raw8)
		raw32, _ = read_u32(&cursor); mutation.patch_blob = model.Blob_Id(raw32)
		raw32, _ = read_u32(&cursor); mutation.content_blob = model.Blob_Id(raw32)
		_ = skip(&cursor, 4)

		before, _ := read_bytes(&cursor, 32)
		copy(mutation.before_hash[:], before)
		after, _ := read_bytes(&cursor, 32)
		copy(mutation.after_hash[:], after)

		append(out, mutation)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Blobs
// ---------------------------------------------------------------------------

BLOB_ROW_SIZE :: 64

// encode_blob_content writes the concatenated bytes of every resident blob and
// rewrites each entry's location to point into that payload.
//
// Content lives in its own chunk kind rather than inside the blob table so a
// reader can load the table — enough to answer "what content does this trace
// reference and how big is it" — without paging in file bytes it may never
// display. docs/04 also requires blob compression to be independent per blob;
// storing them contiguously here keeps that option open without forcing it.
encode_blob_content :: proc(buffer: ^[dynamic]u8, table: ^model.Blob_Table) {
	cursor := Writer_Cursor{data = buffer}
	if !table.content_resident {
		// Nothing to write; entries keep the locations they were decoded with.
		return
	}

	// Each entry's source range is read before any entry is rewritten.
	//
	// Reading and rewriting in one pass would be wrong: blob_content resolves
	// bytes through entry.chunk_offset, so rewriting entry N's offset changes
	// where entry N+1 appears to live, and every later blob would be written
	// from the wrong bytes.
	Source :: struct {
		offset: u64,
		size:   u64,
	}
	sources := make([]Source, len(table.entries), context.temp_allocator)
	defer delete(sources, context.temp_allocator)
	for index in 1 ..< len(table.entries) {
		entry := table.entries[index]
		sources[index] = Source{offset = entry.chunk_offset, size = entry.size}
	}

	for index in 1 ..< len(table.entries) {
		source := sources[index]
		start, start_ok := core.to_int(source.offset)
		length, length_ok := core.to_int(source.size)
		if !start_ok || !length_ok || start + length > len(table.content) {
			continue
		}
		content := table.content[start:start + length]

		// The entry's location is rewritten to its offset within this payload,
		// which is what the reader will index by.
		entry := &table.entries[index]
		entry.chunk_offset = u64(len(buffer))
		entry.stored_size = u64(len(content))
		write_bytes(&cursor, content)
	}
}

// blob_content_from_chunk returns one blob's bytes from a decoded content
// chunk payload, verifying the digest before the content is treated as usable.
//
// docs/04: the reader verifies the digest after decompression before treating
// content as replay-verified. A mismatch is reported rather than repaired,
// because the recorded hash is the evidence and the bytes are the suspect.
blob_content_from_chunk :: proc(
	payload: []byte,
	entry: model.Blob_Entry,
) -> (
	content: []byte,
	err: core.Error,
) {
	start, start_ok := core.to_int(entry.chunk_offset)
	length, length_ok := core.to_int(entry.size)
	if !start_ok || !length_ok {
		return nil, core.err_make(.Malformed_Container, "blob location is not addressable")
	}
	if !core.range_within(entry.chunk_offset, entry.size, u64(len(payload))) {
		return nil, core.err_make(.Truncated_Input, "blob extends past its content chunk")
	}

	content = payload[start:start + length]
	if !model.digest_equal(model.digest_content(content), entry.digest) {
		return nil, core.err_make(
			.Checksum_Mismatch,
			"blob content does not match its recorded digest",
		)
	}
	return content, nil
}

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
