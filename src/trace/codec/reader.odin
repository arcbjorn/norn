package codec

import "core:crypto/hash"

import "src:core"
import "src:trace/model"

// The .norn reader and validator.
//
// docs/04-trace-format.md defines three validation modes:
//   quick  header, footer, directory, bounds, and chunk checksums;
//   full   quick checks plus all blob hashes and semantic invariants;
//   replay full checks plus reconstruction of every mutation chain.
//
// Replay mode arrives with the replay engine. Quick and full are implemented
// here, and both must reject every corruption fixture without panicking or
// allocating beyond the configured limits.

Validation_Mode :: enum u8 {
	Quick  = 0,
	Full   = 1,
	Replay = 2,
}

// Trace is an opened trace. It borrows the caller's byte buffer for the file
// image and owns the collections decoded from it.
//
// `data` must outlive the Trace: entities, events, and strings are copied out,
// but blob payloads are read on demand from the original bytes.
Trace :: struct {
	data:      []byte,
	header:    File_Header,
	footer:    Footer,
	directory: [dynamic]Directory_Entry,
	metadata:  Session_Metadata,

	strings:   model.String_Table,
	blobs:     model.Blob_Table,
	entities:  [dynamic]model.Entity,
	spans:     [dynamic]model.Span,
	events:    [dynamic]model.Event,
	edges:     [dynamic]model.Edge,
	mutations: [dynamic]model.Mutation,
	payloads:  model.Payload_Tables,

	// Payload of the blob content chunk, borrowed from `data`. Blob bytes are
	// resolved out of this on demand rather than copied at open time.
	blob_content: []byte,
}

trace_destroy :: proc(trace: ^Trace) {
	model.string_table_destroy(&trace.strings)
	model.blob_table_destroy(&trace.blobs)
	delete(trace.directory)
	delete(trace.entities)
	delete(trace.spans)
	delete(trace.events)
	delete(trace.edges)
	delete(trace.mutations)
	model.payload_tables_destroy(&trace.payloads)
	trace^ = {}
}

// trace_blob_content returns a blob's bytes, verifying the digest first.
//
// The result borrows the trace's mapped data and stays valid as long as the
// trace is open. A blob whose bytes were never stored returns false with a
// Not_Found category, which replay reports as missing evidence rather than as
// an empty file.
trace_blob_content :: proc(
	trace: ^Trace,
	id: model.Blob_Id,
) -> (
	content: []byte,
	err: core.Error,
) {
	if id == model.NO_BLOB {
		return nil, core.err_make(.Invalid_Argument, "no blob was referenced")
	}
	entry, found := model.blob_get(&trace.blobs, id)
	if !found {
		return nil, core.err_make(.Invalid_Reference, "trace names a blob that does not exist")
	}
	if trace.blob_content == nil {
		return nil, core.err_make(.Not_Found, "trace stores no blob content")
	}
	return blob_content_from_chunk(trace.blob_content, entry)
}

// read_directory parses the header, footer, and directory without decoding any
// content chunk. Every command that only needs chunk-level facts uses this.
@(private)
read_directory :: proc(
	data: []byte,
	limits: core.Limits,
	out: ^[dynamic]Directory_Entry,
) -> (
	header: File_Header,
	footer: Footer,
	err: core.Error,
) {
	header = decode_file_header(data, limits) or_return
	footer = decode_footer(data, header.footer_offset) or_return

	// The header and footer must agree about where the directory is. A
	// disagreement means one of them was tampered with after the other was
	// written, so neither is trustworthy.
	if footer.directory_offset != header.directory_offset {
		return {}, {}, core.err_make(
			.Malformed_Container,
			"header and footer disagree about the directory offset",
		)
	}
	if footer.total_size != u64(len(data)) {
		return {}, {}, core.err_make(
			.Malformed_Container,
			"footer total size disagrees with the file length",
		)
	}

	directory_header := decode_chunk_header(data, header.directory_offset, limits) or_return
	if directory_header.kind != .Directory {
		return {}, {}, core.err_at(
			.Malformed_Container,
			"the directory offset does not point at a directory chunk",
			header.directory_offset,
		)
	}
	payload := chunk_payload(data, header.directory_offset, directory_header) or_return
	decode_directory(payload, out, u64(len(data)), limits) or_return

	return header, footer, nil
}

// validate_quick checks the header, footer, directory, bounds, and every
// chunk's header and payload checksum.
//
// It decodes no chunk payload into typed records, so it stays cheap enough to
// run on every write before the temporary file is published.
validate_quick :: proc(data: []byte, limits := core.DEFAULT_LIMITS) -> core.Error {
	directory := make([dynamic]Directory_Entry, 0, 32, context.temp_allocator)
	defer delete(directory)

	header, footer := read_directory(data, limits, &directory) or_return

	// The footer digest covers every byte between the file header and the
	// footer. Verifying it here means a single flipped bit anywhere in that
	// range is caught even if it landed in a chunk this mode does not decode.
	// The header is covered by its own CRC32C, already checked above.
	computed: [32]u8
	offset, ok := core.to_int(header.footer_offset)
	if !ok {
		return core.err_make(.Malformed_Container, "footer offset is not addressable")
	}
	if offset < FILE_HEADER_SIZE {
		return core.err_make(.Malformed_Container, "footer offset overlaps the file header")
	}
	hash.hash(.SHA256, data[FILE_HEADER_SIZE:offset], computed[:])
	if computed != footer.digest {
		return core.err_make(.Checksum_Mismatch, "file digest does not match the footer")
	}

	// Every chunk the directory names must have a header that agrees with the
	// directory entry and a payload whose checksum matches.
	seen_metadata := false
	for entry, index in directory {
		chunk := decode_chunk_header(data, entry.offset, limits) or_return

		if chunk.kind != entry.kind ||
		   chunk.ordinal != entry.ordinal ||
		   chunk.encoded_size != entry.encoded_size ||
		   chunk.record_count != entry.record_count {
			return core.err_record(
				.Malformed_Container,
				"directory entry disagrees with its chunk header",
				u64(index),
			)
		}
		if is_required_kind(chunk.kind) && chunk.kind == .Invalid {
			return core.err_record(
				.Malformed_Container,
				"directory names an invalid chunk kind",
				u64(index),
			)
		}
		// chunk_payload verifies the payload checksum.
		chunk_payload(data, entry.offset, chunk) or_return

		if chunk.kind == .Metadata {
			seen_metadata = true
		}
	}

	if !seen_metadata {
		return core.err_make(.Malformed_Container, "trace has no metadata chunk")
	}
	return nil
}

// open_trace reads a complete trace into typed collections.
//
// `data` is borrowed and must outlive the returned Trace. On failure the Trace
// is destroyed and nothing is returned, so a caller can never observe a
// partially initialized trace.
open_trace :: proc(
	data: []byte,
	limits := core.DEFAULT_LIMITS,
	allocator := context.allocator,
) -> (
	trace: Trace,
	err: core.Error,
) {
	trace.data = data
	trace.directory = make([dynamic]Directory_Entry, 0, 32, allocator)
	trace.entities = make([dynamic]model.Entity, 0, 64, allocator)
	trace.spans = make([dynamic]model.Span, 0, 64, allocator)
	trace.events = make([dynamic]model.Event, 0, 1024, allocator)
	trace.edges = make([dynamic]model.Edge, 0, 64, allocator)
	model.blob_table_init(&trace.blobs, allocator)
	model.string_table_init(&trace.strings, allocator)
	model.payload_tables_init(&trace.payloads, allocator)

	defer if !core.ok(err) {
		trace_destroy(&trace)
	}

	trace.header, trace.footer = read_directory(data, limits, &trace.directory) or_return

	strings_loaded := false
	metadata_loaded := false

	for entry, index in trace.directory {
		chunk := decode_chunk_header(data, entry.offset, limits) or_return
		if chunk.kind != entry.kind {
			err = core.err_record(
				.Malformed_Container,
				"directory entry disagrees with its chunk header",
				u64(index),
			)
			return
		}
		payload := chunk_payload(data, entry.offset, chunk) or_return

		#partial switch chunk.kind {
		case .Metadata:
			if metadata_loaded {
				err = core.err_make(.Malformed_Container, "trace has more than one metadata chunk")
				return
			}
			trace.metadata = decode_metadata(payload) or_return
			metadata_loaded = true

		case .Strings:
			if strings_loaded {
				err = core.err_make(.Malformed_Container, "trace has more than one strings chunk")
				return
			}
			// decode_strings reinitializes the table, so release the empty one
			// created above to avoid leaking its backing arrays.
			model.string_table_destroy(&trace.strings)
			decode_strings(payload, &trace.strings, limits, allocator) or_return
			strings_loaded = true

		case .Entities:
			decode_entities(payload, &trace.entities, limits) or_return

		case .Spans:
			decode_spans(payload, &trace.spans, limits) or_return

		case .Events:
			decode_events(payload, &trace.events, limits) or_return

		case .Edges:
			decode_edges(payload, &trace.edges, limits) or_return

		case .Payloads:
			decode_payloads(payload, &trace.payloads, limits) or_return

		case .Mutations:
			decode_mutations(payload, &trace.mutations, limits) or_return

		case .Blob_Content:
			// Borrowed, not copied: replay resolves individual blobs out of
			// this payload and verifies each digest at that point.
			trace.blob_content = payload

		case .Blobs:
			decode_blobs(payload, &trace.blobs, limits) or_return
			// Content read back from a trace is not resident in the table; it
			// is fetched through trace_blob_content instead.
			trace.blobs.content_resident = false

		case .Directory, .Footer:
			// Already handled by read_directory.

		case:
			// An unknown optional kind is skipped and preserved; an unknown
			// required kind is a clear unsupported-format error.
			if is_required_kind(chunk.kind) && .Optional not_in chunk.flags {
				err = core.Failure {
					category = .Unsupported_Feature,
					recoverability = .Fatal,
					message = "trace contains an unsupported required chunk kind",
					subject = core.Subject{kind = .Chunk_Ordinal, number = u64(chunk.ordinal)},
				}
				return
			}
		}
	}

	if !metadata_loaded {
		err = core.err_make(.Malformed_Container, "trace has no metadata chunk")
		return
	}
	if !strings_loaded {
		err = core.err_make(.Malformed_Container, "trace has no strings chunk")
		return
	}

	return trace, nil
}

// validate_full runs the quick checks and then the semantic invariants from
// docs/03. A trace that passes may still contain replay gaps; those are
// recorded facts, not validation failures.
validate_full :: proc(data: []byte, limits := core.DEFAULT_LIMITS) -> core.Error {
	validate_quick(data, limits) or_return

	trace, err := open_trace(data, limits, context.temp_allocator)
	if !core.ok(err) {
		return err
	}
	defer trace_destroy(&trace)

	return validate_invariants(&trace)
}

// validate_invariants enforces the numbered invariants in docs/03.
//
// Every check names the invariant it protects, because a failure here is a
// writer bug or a tampered file and the message is the first thing a
// maintainer reads.
validate_invariants :: proc(trace: ^Trace) -> core.Error {
	string_count := u32(model.string_table_count(&trace.strings))
	blob_count := u32(model.blob_table_count(&trace.blobs))

	check_string :: proc(id: model.String_Id, count: u32) -> bool {
		return u32(id) <= count
	}

	// Invariant 1 and 2: event identifiers and sequence numbers strictly
	// increase, and sequences are unique. Strict increase gives uniqueness.
	previous_id := model.Event_Id(0)
	previous_sequence := model.Sequence(0)
	for event, index in trace.events {
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

		// Invariant 3: every referenced string, blob, entity, and span exists.
		if !check_string(event.summary_string_id, string_count) {
			return core.err_record(
				.Invalid_Reference,
				"event names a string that does not exist",
				u64(index),
			)
		}
		if !check_string(event.source.importer_id, string_count) ||
		   !check_string(event.source.importer_version, string_count) ||
		   !check_string(event.source.source_file, string_count) ||
		   !check_string(event.source.source_type, string_count) {
			return core.err_record(
				.Invalid_Reference,
				"event provenance names a string that does not exist",
				u64(index),
			)
		}
		if u32(event.source.raw_blob) > blob_count {
			return core.err_record(
				.Invalid_Reference,
				"event provenance names a blob that does not exist",
				u64(index),
			)
		}
		if event.parent_span_id != model.NO_SPAN &&
		   u64(event.parent_span_id) > u64(len(trace.spans)) {
			return core.err_record(
				.Invalid_Reference,
				"event names a span that does not exist",
				u64(index),
			)
		}
		if event.actor_entity_id != model.NO_ENTITY &&
		   u64(event.actor_entity_id) > u64(len(trace.entities)) {
			return core.err_record(
				.Invalid_Reference,
				"event names an actor entity that does not exist",
				u64(index),
			)
		}
		if event.primary_entity_id != model.NO_ENTITY &&
		   u64(event.primary_entity_id) > u64(len(trace.entities)) {
			return core.err_record(
				.Invalid_Reference,
				"event names a primary entity that does not exist",
				u64(index),
			)
		}
	}

	// Invariant 5: repository paths are normalized and relative.
	for entity, index in trace.entities {
		if !check_string(entity.name, string_count) ||
		   !check_string(entity.qualifier, string_count) {
			return core.err_record(
				.Invalid_Reference,
				"entity names a string that does not exist",
				u64(index),
			)
		}
		if entity.parent != model.NO_ENTITY && u64(entity.parent) > u64(len(trace.entities)) {
			return core.err_record(
				.Invalid_Reference,
				"entity names a parent that does not exist",
				u64(index),
			)
		}
		if entity.kind == .Path {
			path, got := model.string_get(&trace.strings, entity.name)
			if !got {
				return core.err_record(
					.Invalid_Reference,
					"path entity names a string that does not exist",
					u64(index),
				)
			}
			if !core.is_normalized_path(path) {
				return core.err_path(
					.Invalid_Path,
					"path entity is not normalized and repository-relative",
					path,
				)
			}
		}
	}

	// Invariant 4: parent edges are acyclic. Spans nest, so walking parents
	// must terminate; a bounded walk detects a cycle without a visited set.
	for span, index in trace.spans {
		if span.parent != model.NO_SPAN && u64(span.parent) > u64(len(trace.spans)) {
			return core.err_record(
				.Invalid_Reference,
				"span names a parent that does not exist",
				u64(index),
			)
		}
		if !check_string(span.name, string_count) {
			return core.err_record(
				.Invalid_Reference,
				"span names a string that does not exist",
				u64(index),
			)
		}
		if span.end_sequence < span.start_sequence {
			return core.err_record(
				.Invariant_Violation,
				"span ends before it starts",
				u64(index),
			)
		}

		steps := 0
		cursor := span.parent
		for cursor != model.NO_SPAN {
			if steps > len(trace.spans) {
				return core.err_record(
					.Invariant_Violation,
					"span parent chain contains a cycle",
					u64(index),
				)
			}
			position := int(cursor) - 1
			if position < 0 || position >= len(trace.spans) {
				return core.err_record(
					.Invalid_Reference,
					"span parent chain leaves the span table",
					u64(index),
				)
			}
			cursor = trace.spans[position].parent
			steps += 1
		}
	}

	// Invariant 3 for edges, plus the rule that an inferred edge must carry
	// its justification: docs/03 requires a rule identifier and reason.
	for edge, index in trace.edges {
		if !check_string(edge.rule, string_count) || !check_string(edge.reason, string_count) {
			return core.err_record(
				.Invalid_Reference,
				"edge names a string that does not exist",
				u64(index),
			)
		}
		if !endpoint_exists(trace, edge.from) || !endpoint_exists(trace, edge.to) {
			return core.err_record(
				.Invalid_Reference,
				"edge names an endpoint that does not exist",
				u64(index),
			)
		}
		if edge.origin == .Inferred && edge.rule == model.EMPTY_STRING {
			return core.err_record(
				.Invariant_Violation,
				"an inferred edge must name the rule that produced it",
				u64(index),
			)
		}
		if u16(edge.confidence) > model.CONFIDENCE_SCALE {
			return core.err_record(
				.Invariant_Violation,
				"edge confidence exceeds the fixed-point scale",
				u64(index),
			)
		}
	}

	// Invariant 6: mutations for one path have a deterministic order.
	//
	// Mutations are stored in event order, so per-path order follows from the
	// event order already checked above. What must be verified is that each
	// mutation names a real event and path, and that a rename names the path
	// it moved from — a rename missing its source would silently become a
	// create, inventing content identity the trace never recorded.
	previous_event := model.Event_Id(0)
	for mutation, index in trace.mutations {
		if mutation.event_id == model.NO_EVENT ||
		   u64(mutation.event_id) > u64(len(trace.events)) {
			return core.err_record(
				.Invalid_Reference,
				"mutation names an event that does not exist",
				u64(index),
			)
		}
		if mutation.event_id <= previous_event {
			return core.err_record(
				.Invariant_Violation,
				"mutations must be stored in strictly increasing event order",
				u64(index),
			)
		}
		previous_event = mutation.event_id

		if mutation.path == model.NO_ENTITY || u64(mutation.path) > u64(len(trace.entities)) {
			return core.err_record(
				.Invalid_Reference,
				"mutation names a path entity that does not exist",
				u64(index),
			)
		}
		if mutation.op == .Rename {
			if mutation.old_path == model.NO_ENTITY ||
			   u64(mutation.old_path) > u64(len(trace.entities)) {
				return core.err_record(
					.Invariant_Violation,
					"a rename must name the path it moved from",
					u64(index),
				)
			}
		}
		if u32(mutation.patch_blob) > blob_count || u32(mutation.content_blob) > blob_count {
			return core.err_record(
				.Invalid_Reference,
				"mutation names a blob that does not exist",
				u64(index),
			)
		}
	}

	// The metadata's own event count must agree with what the file contains,
	// or the import report would describe a different trace than the one the
	// user is looking at.
	if trace.metadata.canonical_event_count != u64(len(trace.events)) {
		return core.err_make(
			.Invariant_Violation,
			"metadata event count disagrees with the events chunks",
		)
	}

	return nil
}

@(private)
endpoint_exists :: proc(trace: ^Trace, endpoint: model.Endpoint) -> bool {
	switch endpoint.kind {
	case .Event:
		// Event identifiers start at 1 and increase by one per event.
		return endpoint.id >= 1 && endpoint.id <= u64(len(trace.events))
	case .Entity:
		return endpoint.id >= 1 && endpoint.id <= u64(len(trace.entities))
	}
	return false
}

// validate reads a trace at the requested depth.
validate :: proc(
	data: []byte,
	mode: Validation_Mode,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	switch mode {
	case .Quick:
		return validate_quick(data, limits)
	case .Full:
		return validate_full(data, limits)
	case .Replay:
		// Replay validation reconstructs every mutation chain, which requires
		// the replay engine. Reporting this plainly is better than silently
		// running a weaker check and reporting success.
		return core.err_make(
			.Unsupported_Feature,
			"replay validation requires the replay engine, which is not in this build",
		)
	}
	return nil
}
