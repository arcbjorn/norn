package test_importers

import "core:strings"
import "core:testing"

import "src:core"
import api "src:importers/api"
import "src:trace/codec"
import "src:trace/model"

// The record sink and adapter contract.
//
// docs/05: "the sink accepts canonical records in sequence order and provides
// string and blob interning. Importers cannot write container bytes directly."
// These test the guarantees that boundary exists to provide — an adapter
// cannot violate them even by trying.

@(private)
make_sink :: proc(sink: ^api.Sink, redactor: ^api.Redactor) {
	api.redactor_init(redactor)
	api.sink_init(sink, redactor, "test", "1.0.0", "session.jsonl")
}

@(private)
destroy_sink :: proc(sink: ^api.Sink, redactor: ^api.Redactor) {
	api.sink_destroy(sink)
	api.redactor_destroy(redactor)
}

@(test)
identifiers_and_sequences_strictly_increase :: proc(t: ^testing.T) {
	// docs/03 invariants 1 and 2. The sink assigns these rather than the
	// adapter precisely so an adapter cannot break them.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	for index in 0 ..< 20 {
		api.add_event(&sink, api.Event_Input{kind = .File_Modify, record_number = u64(index)})
	}

	testing.expect(t, core.ok(api.validate_invariants(&sink)))

	previous_id := model.Event_Id(0)
	previous_sequence := model.Sequence(0)
	for event in sink.events {
		testing.expect(t, event.id > previous_id)
		testing.expect(t, event.sequence > previous_sequence)
		previous_id = event.id
		previous_sequence = event.sequence
	}
}

@(test)
non_monotonic_timestamps_are_repaired_not_reordered :: proc(t: ^testing.T) {
	// docs/03: importers repair non-monotonic timestamps by preserving source
	// order and recording a warning; they never silently reorder mutations.
	// Source order is what actually happened; a clock that went backwards is a
	// broken clock, not evidence of reordering.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	api.add_event(
		&sink,
		api.Event_Input{kind = .File_Modify, wall_time_ns = 1000, has_wall_time = true},
	)
	api.add_event(
		&sink,
		api.Event_Input{kind = .File_Modify, wall_time_ns = 500, has_wall_time = true},
	)
	api.add_event(
		&sink,
		api.Event_Input{kind = .File_Modify, wall_time_ns = 2000, has_wall_time = true},
	)

	// Order is preserved: the second record is still the second event.
	testing.expect_value(t, len(sink.events), 3)
	testing.expect_value(t, sink.events[1].sequence, model.Sequence(2))

	// Its time was repaired rather than left to run backwards.
	testing.expect_value(t, sink.events[1].time_quality, model.Time_Quality.Repaired)
	testing.expect(t, sink.events[1].wall_time_ns >= sink.events[0].wall_time_ns)

	// The repair is recorded, both as a warning and on the event itself.
	testing.expect_value(
		t,
		sink.report.warnings[int(codec.Warning_Category.Timestamp_Repaired)],
		u32(1),
	)
	testing.expect(t, .Timestamp_Repaired in sink.events[1].source.transforms)
	testing.expect(t, .Order_Preserved in sink.events[1].source.transforms)
	testing.expect_value(t, sink.report.repaired_timestamps, u64(1))
}

@(test)
an_absent_timestamp_is_counted_not_invented :: proc(t: ^testing.T) {
	// docs/03 allows an absent wall time. Substituting one would present a
	// guess as recorded evidence.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	api.add_event(&sink, api.Event_Input{kind = .File_Modify})

	testing.expect(t, .Has_Wall_Time not_in sink.events[0].flags)
	testing.expect_value(t, sink.events[0].time_quality, model.Time_Quality.Unknown)
	testing.expect_value(t, sink.report.absent_timestamps, u64(1))
}

@(test)
source_text_is_redacted_before_interning :: proc(t: ^testing.T) {
	// docs/08 requires redaction before content reaches the writer. Interning
	// the redacted form means the original never enters the string table, so
	// it cannot reach the writer even by mistake.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	api.add_event(
		&sink,
		api.Event_Input{kind = .Command_Start, summary = "cd /Users/someone/projects"},
	)

	// The original must not exist anywhere in the table.
	for id in 0 ..= model.string_table_count(&sink.strings) {
		value, ok := model.string_get(&sink.strings, model.String_Id(id))
		if !ok {
			continue
		}
		testing.expectf(
			t,
			!strings.contains(value, "someone"),
			"the unredacted value reached the string table as %q",
			value,
		)
	}

	summary, _ := model.string_get(&sink.strings, sink.events[0].summary_string_id)
	testing.expect(t, strings.contains(summary, "projects"), "the path tail must survive")
	testing.expect(t, .Redacted in sink.events[0].flags, "the event must be marked redacted")
}

@(test)
redacted_blobs_are_flagged :: proc(t: ^testing.T) {
	// A reader must be able to tell redacted content from content that was
	// simply short.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)
	api.add_literal(&redactor, "hunter2")

	blob := api.add_blob_text(&sink, "password: hunter2\n")
	entry, ok := model.blob_get(&sink.blobs, blob)

	testing.expect(t, ok)
	testing.expect(t, .Redacted in entry.flags, "a redacted blob must say so")

	content, present := model.blob_content(&sink.blobs, blob)
	testing.expect(t, present)
	testing.expect(t, !strings.contains(string(content), "hunter2"))
}

@(test)
entities_are_deduplicated :: proc(t: ^testing.T) {
	// A session that reads one file forty times must produce one path entity,
	// or the repository map would show forty nodes for one file.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	first := api.add_entity(&sink, .Path, "src/parser.odin")
	second := api.add_entity(&sink, .Path, "src/parser.odin")
	different := api.add_entity(&sink, .Path, "src/lexer.odin")
	other_kind := api.add_entity(&sink, .Symbol, "src/parser.odin")

	testing.expect_value(t, first, second)
	testing.expect(t, different != first)
	testing.expect(t, other_kind != first, "kind is part of identity")
	testing.expect_value(t, len(sink.entities), 3)
}

@(test)
every_event_carries_provenance :: proc(t: ^testing.T) {
	// docs/03 requires provenance for auditability and importer debugging.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	api.add_event(
		&sink,
		api.Event_Input{kind = .User_Message, source_type = "message", record_number = 7},
	)

	event := sink.events[0]
	testing.expect_value(t, event.source.record_number, u64(7))

	importer, _ := model.string_get(&sink.strings, event.source.importer_id)
	testing.expect_value(t, importer, "test")

	version, _ := model.string_get(&sink.strings, event.source.importer_version)
	testing.expect_value(t, version, "1.0.0")

	source_file, _ := model.string_get(&sink.strings, event.source.source_file)
	testing.expect_value(t, source_file, "session.jsonl")
}

@(test)
an_unclosed_span_stays_incomplete :: proc(t: ^testing.T) {
	// docs/03: "import must not synthesize a successful end for a span that
	// simply stops." A synthesized end would claim the operation finished.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	open := api.add_span(&sink, .Command_Execution, "odin test")
	closed := api.add_span(&sink, .Tool_Invocation, "read_file")
	event := api.add_event(&sink, api.Event_Input{kind = .Tool_Call, span = closed})
	api.close_span(&sink, closed, event)

	testing.expect(t, .Incomplete in sink.spans[int(open) - 1].flags)
	testing.expect(t, .Incomplete not_in sink.spans[int(closed) - 1].flags)
}

@(test)
mutation_statuses_are_counted_by_replayability :: proc(t: ^testing.T) {
	// docs/05's report distinguishes replayable, partial, and opaque, because
	// a user needs to know how much of a session can actually be reconstructed.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	event := api.add_event(&sink, api.Event_Input{kind = .File_Modify})
	path := api.add_entity(&sink, .Path, "a.odin")

	api.add_mutation(&sink, model.Mutation{event_id = event, path = path, status = .Verified})
	api.add_mutation(
		&sink,
		model.Mutation{event_id = event, path = path, status = .Unsupported_Patch},
	)
	api.add_mutation(
		&sink,
		model.Mutation{event_id = event, path = path, status = .Binary_Opaque},
	)

	testing.expect_value(t, sink.report.replayable_mutations, u64(1))
	testing.expect_value(t, sink.report.partial_mutations, u64(1))
	testing.expect_value(t, sink.report.opaque_mutations, u64(1))
}

@(test)
the_sink_rejects_a_mutation_naming_a_missing_event :: proc(t: ^testing.T) {
	// Catching this here names the adapter that produced it, rather than
	// reporting a corrupt trace after the writer has run.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	api.add_mutation(&sink, model.Mutation{event_id = model.Event_Id(99), path = 1})

	err := api.validate_invariants(&sink)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invalid_Reference)
}

@(test)
the_sink_rejects_a_rename_without_a_source :: proc(t: ^testing.T) {
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	event := api.add_event(&sink, api.Event_Input{kind = .File_Rename})
	api.add_mutation(&sink, model.Mutation{event_id = event, path = 1, op = .Rename})

	err := api.validate_invariants(&sink)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invariant_Violation)
}

@(test)
a_finished_sink_writes_a_valid_trace :: proc(t: ^testing.T) {
	// The end-to-end guarantee: what an adapter produces through the sink is
	// a trace the codec accepts.
	sink: api.Sink
	redactor: api.Redactor
	make_sink(&sink, &redactor)
	defer destroy_sink(&sink, &redactor)

	api.declare_capability(&sink, .Conversation_Text)
	api.declare_capability(&sink, .Wall_Clock_Timestamps)

	path := api.add_entity(&sink, .Path, "src/parser.odin")
	api.add_event(
		&sink,
		api.Event_Input {
			kind = .User_Message,
			summary = "fix the parser",
			wall_time_ns = 1_700_000_000_000_000_000,
			has_wall_time = true,
		},
	)
	event := api.add_event(
		&sink,
		api.Event_Input {
			kind = .File_Modify,
			primary = path,
			wall_time_ns = 1_700_000_001_000_000_000,
			has_wall_time = true,
		},
	)

	blob := api.add_blob_text(&sink, "package parser\n")
	api.add_mutation(
		&sink,
		model.Mutation {
			event_id = event,
			path = path,
			op = .Modify,
			encoding = .Utf8,
			content_blob = blob,
			after_hash = model.digest_content(transmute([]byte)string("package parser\n")),
			flags = {.Has_Content, .Has_After_Hash},
			status = .Verified,
		},
	)

	testing.expect(t, core.ok(api.validate_invariants(&sink)))

	content := api.finish(
		&sink,
		model.Session_Id{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		codec.Session_Metadata{baseline_kind = .None},
	)

	writer: codec.Writer
	codec.writer_init(&writer, content.session_id, 1_700_000_000_000_000_000)
	defer codec.writer_destroy(&writer)

	testing.expect(t, core.ok(codec.writer_write_content(&writer, &content)))
	testing.expect(t, core.ok(codec.writer_finish(&writer)))

	err := codec.validate_full(writer.buffer[:])
	testing.expectf(t, core.ok(err), "the written trace failed validation: %s", core.error_message(err))

	// The capability manifest and counts survive into the metadata.
	trace, open_err := codec.open_trace(writer.buffer[:])
	testing.expect(t, core.ok(open_err))
	defer codec.trace_destroy(&trace)

	testing.expect(t, .Conversation_Text in trace.metadata.capabilities)
	testing.expect_value(t, trace.metadata.canonical_event_count, u64(2))
	testing.expect(t, trace.metadata.file_content_bytes > 0)
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

@(private)
stub_detect_certain :: proc(prefix: []byte, path_hint: string) -> api.Detection {
	result := api.Detection{confidence = .Certain}
	api.add_reason(&result, "version marker present")
	return result
}

@(private)
stub_detect_possible :: proc(prefix: []byte, path_hint: string) -> api.Detection {
	return api.Detection{confidence = .Possible}
}

@(private)
stub_detect_none :: proc(prefix: []byte, path_hint: string) -> api.Detection {
	return api.Detection{confidence = .None}
}

@(test)
a_confident_adapter_is_chosen :: proc(t: ^testing.T) {
	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)

	api.register(&registry, api.Importer{id = "certain", detect = stub_detect_certain})
	api.register(&registry, api.Importer{id = "possible", detect = stub_detect_possible})

	results := api.detect_all(&registry, transmute([]byte)string("data"), "trace.jsonl")
	defer delete(results)

	chosen, ok := api.choose_adapter(results[:])
	testing.expect(t, ok)
	testing.expect_value(t, chosen.id, "certain")
}

@(test)
comparable_confidence_defers_to_the_user :: proc(t: ^testing.T) {
	// docs/05: auto-detection proceeds only when no adapter has comparable
	// confidence. Importing with the wrong adapter produces a
	// plausible-looking trace of the wrong session, which is worse than asking.
	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)

	api.register(&registry, api.Importer{id = "first", detect = stub_detect_certain})
	api.register(&registry, api.Importer{id = "second", detect = stub_detect_certain})

	results := api.detect_all(&registry, transmute([]byte)string("data"), "trace.jsonl")
	defer delete(results)

	_, ok := api.choose_adapter(results[:])
	testing.expect(t, !ok, "two equally confident adapters must not auto-select")
}

@(test)
weak_confidence_defers_to_the_user :: proc(t: ^testing.T) {
	// A JSONL file is not a Codex trace merely because it is JSONL.
	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)

	api.register(&registry, api.Importer{id = "possible", detect = stub_detect_possible})

	results := api.detect_all(&registry, transmute([]byte)string("data"), "trace.jsonl")
	defer delete(results)

	_, ok := api.choose_adapter(results[:])
	testing.expect(t, !ok, "a merely possible match must not auto-select")
}

@(test)
an_unmatched_source_yields_no_results :: proc(t: ^testing.T) {
	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)

	api.register(&registry, api.Importer{id = "none", detect = stub_detect_none})

	results := api.detect_all(&registry, transmute([]byte)string("data"), "trace.jsonl")
	defer delete(results)

	testing.expect_value(t, len(results), 0)
	_, ok := api.choose_adapter(results[:])
	testing.expect(t, !ok)
}

@(test)
detection_reasons_are_reported :: proc(t: ^testing.T) {
	// The reasons are shown when detection is ambiguous, so a user can choose
	// on evidence rather than on a name.
	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)
	api.register(&registry, api.Importer{id = "certain", detect = stub_detect_certain})

	results := api.detect_all(&registry, transmute([]byte)string("data"), "trace.jsonl")
	defer delete(results)

	testing.expect_value(t, len(results), 1)
	detection := results[0].detection
	testing.expect_value(t, len(api.reasons(&detection)), 1)
	testing.expect_value(t, api.reasons(&detection)[0], "version marker present")
}

@(test)
detection_sees_only_a_bounded_prefix :: proc(t: ^testing.T) {
	// Detection runs against every registered adapter, so a hostile file must
	// not be parsed in full several times before one adapter claims it.
	observed := 0

	capture :: proc(prefix: []byte, path_hint: string) -> api.Detection {
		// The prefix must never exceed the documented bound.
		if len(prefix) > api.DETECTION_PREFIX {
			return api.Detection{confidence = .None}
		}
		return api.Detection{confidence = .Likely}
	}

	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)
	api.register(&registry, api.Importer{id = "capture", detect = capture})

	large := make([]byte, api.DETECTION_PREFIX * 4)
	defer delete(large)

	results := api.detect_all(&registry, large, "big.jsonl")
	defer delete(results)

	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].detection.confidence, api.Confidence.Likely)
	_ = observed
}
