package importer_api

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// The record sink.
//
// docs/05-importers.md: "the sink accepts canonical records in sequence order
// and provides string and blob interning. Importers cannot write container
// bytes directly."
//
// That boundary is what keeps a provider adapter from being able to corrupt a
// trace. An adapter describes what it saw; the sink assigns identifiers,
// enforces ordering, applies redaction, and hands the result to the writer.

// Sink accumulates canonical records for one import.
Sink :: struct {
	strings:   model.String_Table,
	blobs:     model.Blob_Table,
	payloads:  model.Payload_Tables,
	entities:  [dynamic]model.Entity,
	spans:     [dynamic]model.Span,
	events:    [dynamic]model.Event,
	edges:     [dynamic]model.Edge,
	mutations: [dynamic]model.Mutation,

	// Redaction runs inside the sink rather than in the adapter, so an adapter
	// cannot forget it. docs/08 requires it before content reaches the writer.
	redactor: ^Redactor,

	// Identifier assignment. docs/03: identifiers and sequences strictly
	// increase and are never reused.
	next_event:    model.Event_Id,
	next_sequence: model.Sequence,
	next_entity:   model.Entity_Id,
	next_span:     model.Span_Id,

	// Provenance stamped onto every event.
    importer_id:      model.String_Id,
	importer_version: model.String_Id,
	source_file:      model.String_Id,

	// Timestamp repair state. docs/03: importers repair non-monotonic
	// timestamps by preserving source order and recording a warning; they
	// never silently reorder mutations.
	last_wall_time: i64,
	has_last_time:  bool,

	report: Import_Report,
}

// Import_Report is the summary docs/05 requires, both displayed and stored.
Import_Report :: struct {
	source_records:  u64,
	canonical_events: u64,
	extension_events: u64,
	ignored_records:  u64,

	warnings:   [codec.WARNING_CATEGORY_COUNT]u32,
	redactions: [codec.REDACTION_CATEGORY_COUNT]u32,

	replayable_mutations: u64,
	partial_mutations:    u64,
	opaque_mutations:     u64,

	// Timestamp quality counts, so a trace whose clock was unreliable says so.
	exact_timestamps:    u64,
	repaired_timestamps: u64,
	absent_timestamps:   u64,

	capabilities: codec.Capabilities,
}

// sink_init prepares a sink for one import.
sink_init :: proc(
	sink: ^Sink,
	redactor: ^Redactor,
	importer_id: string,
	importer_version: string,
	source_file: string,
	allocator := context.allocator,
) {
	model.string_table_init(&sink.strings, allocator)
	model.blob_table_init(&sink.blobs, allocator)
	model.payload_tables_init(&sink.payloads, allocator)
	sink.entities = make([dynamic]model.Entity, 0, 32, allocator)
	sink.spans = make([dynamic]model.Span, 0, 16, allocator)
	sink.events = make([dynamic]model.Event, 0, 1024, allocator)
	sink.edges = make([dynamic]model.Edge, 0, 64, allocator)
	sink.mutations = make([dynamic]model.Mutation, 0, 64, allocator)

	sink.redactor = redactor
	sink.next_event = model.FIRST_EVENT
	sink.next_sequence = model.FIRST_SEQUENCE
	sink.next_entity = 1
	sink.next_span = 1

	sink.importer_id = intern(sink, importer_id)
	sink.importer_version = intern(sink, importer_version)
	sink.source_file = intern(sink, source_file)
}

sink_destroy :: proc(sink: ^Sink) {
	model.string_table_destroy(&sink.strings)
	model.blob_table_destroy(&sink.blobs)
	model.payload_tables_destroy(&sink.payloads)
	delete(sink.entities)
	delete(sink.spans)
	delete(sink.events)
	delete(sink.edges)
	delete(sink.mutations)
	sink^ = {}
}

// intern adds a string without redacting it.
//
// For structural values an adapter controls: a kind name, a fixed label. Any
// value originating in the source goes through intern_text instead.
intern :: proc(sink: ^Sink, value: string) -> model.String_Id {
	id, ok := model.string_intern(&sink.strings, value)
	if !ok {
		sink.report.warnings[int(codec.Warning_Category.Content_Truncated)] += 1
		return model.EMPTY_STRING
	}
	return id
}

// intern_text redacts a source-derived string and then interns it.
//
// Every value that came from the provider goes through here. Interning the
// redacted form means the original never enters the string table, so it cannot
// reach the writer even by mistake.
intern_text :: proc(sink: ^Sink, value: string) -> model.String_Id {
	if value == "" {
		return model.EMPTY_STRING
	}
	if sink.redactor == nil {
		return intern(sink, value)
	}

	before := total_redactions(sink.redactor)
	redacted := redact(sink.redactor, value, context.temp_allocator)
	defer delete(redacted, context.temp_allocator)

	if total_redactions(sink.redactor) > before {
		sink.report.redactions = sink.redactor.counts
	}
	return intern(sink, redacted)
}

// add_blob_text redacts and stores content.
add_blob_text :: proc(
	sink: ^Sink,
	content: string,
	encoding := model.Text_Encoding.Utf8,
) -> model.Blob_Id {
	if content == "" {
		return model.NO_BLOB
	}

	text := content
	redacted: string
	if sink.redactor != nil {
		redacted = redact(sink.redactor, content, context.temp_allocator)
		text = redacted
		sink.report.redactions = sink.redactor.counts
	}
	defer if redacted != "" {
		delete(redacted, context.temp_allocator)
	}

	flags: model.Blob_Flags
	if contains_marker(text) {
		flags += {.Redacted}
	}

	id, ok := model.blob_add(&sink.blobs, transmute([]byte)text, model.EMPTY_STRING, encoding, flags)
	if !ok {
		sink.report.warnings[int(codec.Warning_Category.Content_Truncated)] += 1
		return model.NO_BLOB
	}
	return id
}

// add_entity registers a subject, deduplicating by kind and name.
//
// Deduplication matters: a session that reads one file forty times must
// produce one path entity, or the repository map would show forty nodes for
// one file.
add_entity :: proc(
	sink: ^Sink,
	kind: model.Entity_Kind,
	name: string,
	qualifier: string = "",
) -> model.Entity_Id {
	name_id := intern_text(sink, name)
	qualifier_id := intern_text(sink, qualifier)

	for entity in sink.entities {
		if entity.kind == kind && entity.name == name_id && entity.qualifier == qualifier_id {
			return entity.id
		}
	}

	id := sink.next_entity
	sink.next_entity += 1
	append(
		&sink.entities,
		model.Entity{id = id, kind = kind, name = name_id, qualifier = qualifier_id},
	)
	return id
}

// Event_Input is what an adapter describes.
//
// Identifiers, sequence, and provenance are the sink's to assign, so they are
// absent here: an adapter that could choose an event identifier could violate
// the strictly-increasing invariant docs/03 requires.
Event_Input :: struct {
	kind:         model.Event_Kind,
	wall_time_ns: i64,
	has_wall_time: bool,
	duration_ns:  i64,
	has_duration: bool,
	span:         model.Span_Id,
	actor:        model.Entity_Id,
	primary:      model.Entity_Id,
	summary:      string,
	payload:      model.Payload_Ref,

	// Source provenance the adapter knows.
	source_type:   string,
	record_number: u64,
	byte_offset:   u64,
}

// add_event appends an event, assigning identity and repairing time.
add_event :: proc(sink: ^Sink, input: Event_Input) -> model.Event_Id {
	id := sink.next_event
	sink.next_event += 1

	flags: model.Event_Flags
	transforms: model.Transform_Flags
	quality := model.Time_Quality.Unknown
	wall_time := input.wall_time_ns

	if input.has_wall_time {
		// docs/03: importers repair non-monotonic timestamps by preserving
		// source order and recording a warning. Source order is authoritative
		// because it is what actually happened; a clock that went backwards is
		// a broken clock, not evidence of reordering.
		if sink.has_last_time && wall_time < sink.last_wall_time {
			wall_time = sink.last_wall_time
			quality = .Repaired
			transforms += {.Timestamp_Repaired, .Order_Preserved}
			sink.report.warnings[int(codec.Warning_Category.Timestamp_Repaired)] += 1
			sink.report.repaired_timestamps += 1
		} else {
			quality = .Exact
			sink.report.exact_timestamps += 1
		}
		flags += {.Has_Wall_Time}
		sink.last_wall_time = wall_time
		sink.has_last_time = true
	} else {
		sink.report.absent_timestamps += 1
	}

	if input.has_duration && input.duration_ns > 0 {
		flags += {.Has_Duration}
	}

	summary_id := intern_text(sink, input.summary)
	if contains_marker_id(sink, summary_id) {
		flags += {.Redacted}
		transforms += {.Redacted}
	}

	append(
		&sink.events,
		model.Event {
			id = id,
			sequence = sink.next_sequence,
			kind = input.kind,
			flags = flags,
			time_quality = quality,
			wall_time_ns = wall_time,
			duration_ns = input.duration_ns,
			parent_span_id = input.span,
			actor_entity_id = input.actor,
			primary_entity_id = input.primary,
			summary_string_id = summary_id,
			payload = input.payload,
			source = model.Source_Ref {
				importer_id = sink.importer_id,
				importer_version = sink.importer_version,
				source_file = sink.source_file,
				source_type = intern(sink, input.source_type),
				record_number = input.record_number,
				byte_offset = input.byte_offset,
				transforms = transforms,
			},
		},
	)

	sink.next_sequence += 1
	sink.report.canonical_events += 1
	if input.kind == .Extension_Event {
		sink.report.extension_events += 1
	}
	return id
}

@(private)
contains_marker_id :: proc(sink: ^Sink, id: model.String_Id) -> bool {
	if id == model.EMPTY_STRING {
		return false
	}
	value, ok := model.string_get(&sink.strings, id)
	return ok && contains_marker(value)
}

// add_mutation records a file change against an event.
add_mutation :: proc(sink: ^Sink, mutation: model.Mutation) {
	append(&sink.mutations, mutation)

	switch mutation.status {
	case .Verified, .Reconstructed_Unverified:
		sink.report.replayable_mutations += 1
	case .Binary_Opaque:
		sink.report.opaque_mutations += 1
	case .Missing_Baseline, .Unsupported_Patch, .Hash_Mismatch:
		sink.report.partial_mutations += 1
	}
}

// add_span opens a span and returns its identifier.
add_span :: proc(sink: ^Sink, kind: model.Span_Kind, name: string) -> model.Span_Id {
	id := sink.next_span
	sink.next_span += 1
	append(
		&sink.spans,
		model.Span {
			id = id,
			kind = kind,
			flags = {.Incomplete},
			name = intern_text(sink, name),
			start_sequence = sink.next_sequence,
			end_sequence = sink.next_sequence,
		},
	)
	return id
}

// close_span records a span's end.
//
// docs/03: "import must not synthesize a successful end for a span that simply
// stops." A span never closed keeps its Incomplete flag and is reported.
close_span :: proc(sink: ^Sink, id: model.Span_Id, start_event: model.Event_Id) {
	index := int(id) - 1
	if index < 0 || index >= len(sink.spans) {
		return
	}
	sink.spans[index].flags -= {.Incomplete}
	sink.spans[index].start_event = start_event
	sink.spans[index].end_sequence = sink.next_sequence
}

// add_edge records a relationship.
add_edge :: proc(sink: ^Sink, edge: model.Edge) {
	append(&sink.edges, edge)
}

// note_warning increments a warning counter.
//
// docs/05 requires a warning for every repair, truncation, ambiguity, or
// unsupported construct, and docs/01 keeps them in session metadata rather
// than letting them vanish with the import dialog.
note_warning :: proc(sink: ^Sink, category: codec.Warning_Category) {
	sink.report.warnings[int(category)] += 1
}

// note_ignored records a source record the adapter did not map.
//
// docs/05: unsupported records are preserved or explicitly counted. Counting
// is the minimum; silence is not an option, because a user cannot tell an
// ignored record from one that was never there.
note_ignored :: proc(sink: ^Sink) {
	sink.report.ignored_records += 1
}

// declare_capability records what the source actually provided.
//
// docs/05: the UI derives feature availability from this manifest, and
// "missing data is not an error and must not be presented as recorded
// evidence."
declare_capability :: proc(sink: ^Sink, capability: codec.Capability) {
	sink.report.capabilities += {capability}
}

// finish assembles the trace content for the writer.
//
// The sink retains ownership of every table, so the returned content borrows
// and stays valid until sink_destroy.
finish :: proc(
	sink: ^Sink,
	session_id: model.Session_Id,
	metadata: codec.Session_Metadata,
) -> codec.Trace_Content {
	complete := metadata
	complete.importer_id = sink.importer_id
	complete.importer_version = sink.importer_version
	complete.canonical_event_count = u64(len(sink.events))
	complete.source_record_count = sink.report.source_records
	complete.extension_event_count = sink.report.extension_events
	complete.ignored_record_count = sink.report.ignored_records
	complete.warnings = sink.report.warnings
	complete.redactions = sink.report.redactions
	complete.capabilities = sink.report.capabilities

	// Count content bytes, which docs/08 requires the metadata panel to show
	// so a user knows how much of their repository a trace carries.
	content_bytes := u64(0)
	for index in 1 ..< len(sink.blobs.entries) {
		content_bytes += sink.blobs.entries[index].size
	}
	complete.file_content_bytes = content_bytes

	return codec.Trace_Content {
		session_id = session_id,
		metadata = complete,
		strings = &sink.strings,
		blobs = &sink.blobs,
		entities = sink.entities[:],
		spans = sink.spans[:],
		events = sink.events[:],
		edges = sink.edges[:],
		mutations = sink.mutations[:],
		payloads = &sink.payloads,
	}
}

// validate_invariants checks what the sink can before the writer runs.
//
// The codec validates a finished file, but catching a violation here names the
// adapter that produced it rather than reporting a corrupt trace after the
// fact.
validate_invariants :: proc(sink: ^Sink) -> core.Error {
	previous_id := model.Event_Id(0)
	previous_sequence := model.Sequence(0)

	for event, index in sink.events {
		if event.id <= previous_id {
			return core.err_record(
				.Invariant_Violation,
				"event identifiers must strictly increase",
				u64(index),
			)
		}
		if event.sequence <= previous_sequence {
			return core.err_record(
				.Invariant_Violation,
				"event sequences must strictly increase",
				u64(index),
			)
		}
		previous_id = event.id
		previous_sequence = event.sequence
	}

	for mutation, index in sink.mutations {
		if mutation.event_id == model.NO_EVENT ||
		   u64(mutation.event_id) > u64(len(sink.events)) {
			return core.err_record(
				.Invalid_Reference,
				"mutation names an event that does not exist",
				u64(index),
			)
		}
		if mutation.op == .Rename && mutation.old_path == model.NO_ENTITY {
			return core.err_record(
				.Invariant_Violation,
				"a rename must name the path it moved from",
				u64(index),
			)
		}
	}

	return nil
}
