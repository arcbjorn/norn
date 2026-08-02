package test_nsl

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import "src:core"
import api "src:importers/api"
import "src:importers/nsl"
import "src:trace/codec"
import "src:trace/model"

// The NSL adapter.
//
// docs/14 defines the format; docs/05 lists the ten things an adapter must do
// with it. These tests are organised around those requirements, because the
// adapter exists to be the worked reference for them.
//
// Every fixture here is written inline. Per docs/05 they contain no
// credentials, prompts, usernames, home paths, or source from real projects.

@(private)
Harness :: struct {
	sink:     api.Sink,
	redactor: api.Redactor,
}

@(private)
begin :: proc(harness: ^Harness) {
	api.redactor_init(&harness.redactor)
	api.sink_init(&harness.sink, &harness.redactor, nsl.ID, nsl.VERSION, "session.jsonl")
}

@(private)
finish :: proc(harness: ^Harness) {
	api.sink_destroy(&harness.sink)
	api.redactor_destroy(&harness.redactor)
}

// run imports a log and returns the sink, failing the test on refusal.
@(private)
run :: proc(t: ^testing.T, harness: ^Harness, log: string) -> ^api.Sink {
	err := nsl.import_source(transmute([]byte)log, &harness.sink, api.Options{})
	testing.expectf(t, core.ok(err), "the log should import: %v", err)
	return &harness.sink
}

@(private)
HEADER :: `{"type":"session","nsl_version":1}`

@(private)
count_kind :: proc(sink: ^api.Sink, kind: model.Event_Kind) -> int {
	total := 0
	for event in sink.events {
		if event.kind == kind {
			total += 1
		}
	}
	return total
}

@(private)
first_of_kind :: proc(
	sink: ^api.Sink,
	kind: model.Event_Kind,
) -> (
	event: model.Event,
	found: bool,
) {
	for candidate in sink.events {
		if candidate.kind == kind {
			return candidate, true
		}
	}
	return {}, false
}

@(private)
text_of :: proc(sink: ^api.Sink, id: model.String_Id) -> string {
	value, _ := model.string_get(&sink.strings, id)
	return value
}

// Detection.

@(test)
a_versioned_header_is_recognised_decisively :: proc(t: ^testing.T) {
	// docs/05 requires a "version marker or equally decisive signal" for
	// Certain confidence.
	detection := nsl.detect(transmute([]byte)string(HEADER), "session.jsonl")

	testing.expect_value(t, detection.confidence, api.Confidence.Certain)
	testing.expect(t, len(api.reasons(&detection)) > 0, "a claim must state its reasons")
}

@(test)
plain_jsonl_is_not_claimed_confidently :: proc(t: ^testing.T) {
	// docs/05: "a JSONL file is not a Codex trace merely because it is JSONL."
	// The same restraint applies here.
	log := `{"type":"message","role":"user","text":"hello"}`
	detection := nsl.detect(transmute([]byte)log, "other.jsonl")

	testing.expect(
		t,
		detection.confidence < .Likely,
		"a file without an NSL header must not be claimed",
	)
}

@(test)
an_unrelated_file_is_not_claimed :: proc(t: ^testing.T) {
	for content in ([]string{"", "hello world", "<html></html>", "\x00\x01\x02"}) {
		detection := nsl.detect(transmute([]byte)content, "notes.txt")
		testing.expectf(
			t,
			detection.confidence == .None,
			"%q must not be claimed",
			content,
		)
	}
}

@(test)
an_unsupported_version_is_claimed_then_refused :: proc(t: ^testing.T) {
	// Claiming it is what produces "unsupported version" rather than "no
	// importer recognizes this file", which would send a user looking for a
	// missing adapter that does not exist.
	log := `{"type":"session","nsl_version":99}`

	detection := nsl.detect(transmute([]byte)log, "session.jsonl")
	testing.expect_value(t, detection.confidence, api.Confidence.Certain)

	harness: Harness
	begin(&harness)
	defer finish(&harness)

	err := nsl.import_source(transmute([]byte)log, &harness.sink, api.Options{})
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Unsupported_Version)
}

@(test)
a_log_without_a_header_is_refused :: proc(t: ^testing.T) {
	// Refusal is reserved for what makes a log meaningless. A missing header
	// means the version is unknown, so no rule for reading it applies.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := `{"type":"message","role":"user","text":"hello"}`
	err := nsl.import_source(transmute([]byte)log, &harness.sink, api.Options{})

	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Malformed_Container)
}

// Requirement 2: source order becomes canonical sequence order.

@(test)
source_order_becomes_sequence_order :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":30,"role":"user","text":"third"}`, "\n",
			`{"type":"message","t":10,"role":"user","text":"first by clock"}`, "\n",
			`{"type":"message","t":20,"role":"user","text":"second by clock"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	// docs/03: importers repair non-monotonic timestamps by preserving source
	// order. The clock went backwards; the order recorded does not.
	testing.expect_value(t, len(sink.events), 3)
	testing.expect_value(t, text_of(sink, sink.events[0].summary_string_id), "third")
	testing.expect_value(t, text_of(sink, sink.events[1].summary_string_id), "first by clock")

	previous := model.Sequence(0)
	for event in sink.events {
		testing.expect(t, event.sequence > previous)
		previous = event.sequence
	}

	testing.expect(t, sink.report.repaired_timestamps > 0, "the repair must be counted")
}

// Requirement 3: visible messages are mapped.

@(test)
each_role_maps_to_its_event_kind :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"a"}`, "\n",
			`{"type":"message","t":2,"role":"assistant","text":"b"}`, "\n",
			`{"type":"message","t":3,"role":"system","text":"c"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .User_Message), 1)
	testing.expect_value(t, count_kind(sink, .Agent_Message), 1)
	testing.expect_value(t, count_kind(sink, .System_Message), 1)
	testing.expect(t, .Conversation_Text in sink.report.capabilities)
}

@(test)
an_unknown_role_is_kept_and_warned_about :: proc(t: ^testing.T) {
	// The text was visible in the session. An unknown role is a reason to warn,
	// not to discard content the user may need to read.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"message","t":1,"role":"oracle","text":"kept"}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.events), 1)
	testing.expect_value(t, sink.report.warnings[int(codec.Warning_Category.Unsupported_Record)], 1)
	testing.expect_value(t, sink.report.ignored_records, 0)
}

// Requirement 4: tool calls pair with results by explicit identifier.

@(test)
a_result_pairs_with_its_call_by_identifier :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	// Interleaved, so proximity would pair them wrongly and only the
	// identifiers give the right answer.
	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"tool_call","t":1,"id":"a","tool":"read","arguments":{"path":"x"}}`, "\n",
			`{"type":"tool_call","t":2,"id":"b","tool":"write","arguments":{"path":"y"}}`, "\n",
			`{"type":"tool_result","t":3,"id":"b","status":"ok","content":"wrote"}`, "\n",
			`{"type":"tool_result","t":4,"id":"a","status":"ok","content":"read"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.spans), 2)
	for span in sink.spans {
		testing.expect(t, .Incomplete not_in span.flags, "both spans must close")
	}

	// The first result belongs to the second call's span.
	write_span := sink.spans[1].id
	results := 0
	for event in sink.events {
		if event.kind != .Tool_Result {
			continue
		}
		results += 1
		if results == 1 {
			testing.expect_value(t, event.parent_span_id, write_span)
		}
	}
	testing.expect_value(t, results, 2)
	testing.expect_value(t, sink.report.warnings[int(codec.Warning_Category.Ambiguous_Pairing)], 0)
}

@(test)
an_unpaired_result_is_kept_and_warned_about :: proc(t: ^testing.T) {
	// docs/05 wants explicit identifiers used when available. Attaching an
	// orphan to the nearest call would fabricate a relationship the source
	// never stated.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"tool_call","t":1,"id":"a","tool":"read","arguments":{}}`, "\n",
			`{"type":"tool_result","t":2,"id":"missing","status":"ok","content":"x"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .Tool_Result), 1)
	testing.expect(t, sink.report.warnings[int(codec.Warning_Category.Ambiguous_Pairing)] > 0)

	// The call never closed, and is not given a synthetic successful end.
	testing.expect(t, .Incomplete in sink.spans[0].flags)
	testing.expect(t, sink.report.warnings[int(codec.Warning_Category.Span_Incomplete)] > 0)
}

@(test)
a_failed_tool_result_is_an_error_event :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"tool_call","t":1,"id":"a","tool":"read","arguments":{}}`, "\n",
			`{"type":"tool_result","t":2,"id":"a","status":"error","error":"no such file"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .Tool_Error), 1)
	testing.expect_value(t, count_kind(sink, .Tool_Result), 0)

	event, found := first_of_kind(sink, .Tool_Error)
	testing.expect(t, found)
	testing.expect_value(t, text_of(sink, event.summary_string_id), "no such file")
}

@(test)
structured_arguments_are_marked_structured :: proc(t: ^testing.T) {
	// docs/03: tool payloads are structured blobs when valid JSON and opaque
	// text otherwise, so a viewer does not try to parse text that never was.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"tool_call","t":1,"id":"a","tool":"x","arguments":{"path":"p"}}`, "\n",
			`{"type":"tool_call","t":2,"id":"b","tool":"y","arguments":"plain text"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.payloads.tools), 2)
	testing.expect(t, sink.payloads.tools[0].structured, "an object is structured")
	testing.expect(t, !sink.payloads.tools[1].structured, "a string is opaque text")
}

// Requirement 6: file observations and mutations.

@(test)
each_file_operation_maps_to_its_kind :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"file","t":1,"op":"read","path":"a.txt"}`, "\n",
			`{"type":"file","t":2,"op":"create","path":"b.txt","after":"new\n"}`, "\n",
			`{"type":"file","t":3,"op":"modify","path":"b.txt","before":"new\n","after":"mod\n"}`, "\n",
			`{"type":"file","t":4,"op":"delete","path":"b.txt"}`, "\n",
			`{"type":"file","t":5,"op":"rename","path":"c.txt","from":"a.txt"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .File_Read), 1)
	testing.expect_value(t, count_kind(sink, .File_Create), 1)
	testing.expect_value(t, count_kind(sink, .File_Modify), 1)
	testing.expect_value(t, count_kind(sink, .File_Delete), 1)
	testing.expect_value(t, count_kind(sink, .File_Rename), 1)

	// A read is an observation, not a mutation.
	testing.expect_value(t, len(sink.mutations), 4)
	testing.expect(t, core.ok(api.validate_invariants(sink)))
}

@(test)
content_evidence_sets_replay_status :: proc(t: ^testing.T) {
	// docs/05's preference order. A mutation without enough content to replay
	// is recorded as a gap, never silently completed from later state.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"file","t":1,"op":"modify","path":"a.txt","before":"x\n","after":"y\n"}`, "\n",
			`{"type":"file","t":2,"op":"modify","path":"b.txt"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.mutations), 2)
	testing.expect_value(t, sink.mutations[0].status, model.Replay_Status.Reconstructed_Unverified)
	testing.expect(t, .Has_Before_Hash in sink.mutations[0].flags)
	testing.expect(t, .Has_After_Hash in sink.mutations[0].flags)

	testing.expect_value(t, sink.mutations[1].status, model.Replay_Status.Missing_Baseline)
	testing.expect(t, sink.report.warnings[int(codec.Warning_Category.Missing_Baseline)] > 0)
}

@(test)
a_path_outside_the_repository_is_refused :: proc(t: ^testing.T) {
	// docs/08: a path is never resolved outside the repository boundary. It is
	// refused rather than clamped, because a clamped path names a different
	// file than the session touched.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"file","t":1,"op":"modify","path":"../../etc/passwd","after":"x"}`, "\n",
			`{"type":"file","t":2,"op":"modify","path":"/etc/passwd","after":"x"}`, "\n",
			`{"type":"file","t":3,"op":"modify","path":"ok.txt","after":"x"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.mutations), 1)
	testing.expect_value(t, sink.report.warnings[int(codec.Warning_Category.Path_Rejected)], 2)
	testing.expect_value(t, sink.report.ignored_records, 2)
}

@(test)
a_rename_without_a_source_degrades_rather_than_breaking :: proc(t: ^testing.T) {
	// docs/03: a rename must name the path it moved from. Writing it as a
	// rename anyway would produce a mutation the writer rejects.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"file","t":1,"op":"rename","path":"b.txt"}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.mutations), 1)
	testing.expect(t, sink.mutations[0].op != .Rename, "it cannot be recorded as a rename")
	testing.expect(t, core.ok(api.validate_invariants(sink)))
}

// Requirement 7: command output is separate from diagnostics.

@(test)
a_command_produces_a_lifecycle_and_its_own_output_event :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"command","t":1,"command":"odin test","argv":["odin","test"],"exit":1,"output":"failed"}`,
			"\n",
			`{"type":"diagnostic","t":2,"severity":"error","path":"a.odin","line":3,"message":"oops"}`,
			"\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .Command_Start), 1)
	testing.expect_value(t, count_kind(sink, .Command_Output), 1)
	testing.expect_value(t, count_kind(sink, .Command_End), 1)
	// The diagnostic is its own event, not folded into command output.
	testing.expect_value(t, count_kind(sink, .Diagnostic), 1)

	testing.expect_value(t, len(sink.payloads.commands), 1)
	command := sink.payloads.commands[0]
	testing.expect(t, command.has_argv, "a real argument vector was supplied")
	testing.expect_value(t, command.argv_count, u32(2))
	testing.expect_value(t, command.status, model.Outcome_Status.Failed)
	testing.expect_value(t, command.exit_code, i32(1))
}

@(test)
a_command_line_is_never_parsed_into_arguments :: proc(t: ^testing.T) {
	// docs/03: a shell command string remains text and is never parsed as if it
	// were a trustworthy argv.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"command","t":1,"command":"echo a && rm -rf b","exit":0}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.payloads.commands), 1)
	testing.expect(t, !sink.payloads.commands[0].has_argv, "no vector was supplied")
	testing.expect_value(t, sink.payloads.commands[0].argv_count, u32(0))
}

@(test)
a_command_without_an_exit_leaves_its_span_incomplete :: proc(t: ^testing.T) {
	// docs/03: "import must not synthesize a successful end for a span that
	// simply stops."
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"command","t":1,"command":"sleep 100"}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .Command_End), 0)
	testing.expect(t, .Incomplete in sink.spans[0].flags)
	testing.expect(t, sink.report.warnings[int(codec.Warning_Category.Span_Incomplete)] > 0)
}

@(test)
a_diagnostic_carries_its_location :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"diagnostic","t":1,"severity":"error","path":"a.odin","line":12,"column":3,"code":"E1","message":"undefined"}`,
			"\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.payloads.diagnostics), 1)
	diagnostic := sink.payloads.diagnostics[0]
	testing.expect_value(t, diagnostic.severity, model.Severity.Error)
	testing.expect_value(t, diagnostic.line, u32(12))
	testing.expect_value(t, diagnostic.column, u32(3))
	// The path is an entity, so a diagnostic and a mutation naming one file are
	// recognizably about one subject.
	testing.expect(t, model.diagnostic_has_location(diagnostic))
}

@(test)
a_test_result_establishes_a_stable_identity :: proc(t: ^testing.T) {
	// docs/06: comparability rests on a stable test identity, established at
	// import rather than by string comparison during analysis.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"test","t":1,"name":"parses","suite":"nsl","status":"fail","message":"no"}`, "\n",
			`{"type":"test","t":2,"name":"parses","suite":"nsl","status":"pass"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, len(sink.payloads.tests), 2)
	// One identity across both runs, which is what makes them comparable.
	testing.expect_value(t, sink.payloads.tests[0].test_case, sink.payloads.tests[1].test_case)
	testing.expect_value(t, sink.payloads.tests[0].status, model.Outcome_Status.Failed)
	testing.expect_value(t, sink.payloads.tests[1].status, model.Outcome_Status.Passed)
	testing.expect(t, .Structured_Tests in sink.report.capabilities)
}

// Requirement 9: unknown records are retained.

@(test)
an_unknown_record_becomes_an_extension_event :: proc(t: ^testing.T) {
	// docs/05: retained rather than dropped, so a later version of Norn can
	// interpret what this one could not.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"checkpoint","t":5,"label":"something new"}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .Extension_Event), 1)
	testing.expect_value(t, sink.report.extension_events, 1)
	testing.expect_value(t, sink.report.ignored_records, 0)

	event, found := first_of_kind(sink, .Extension_Event)
	testing.expect(t, found)
	testing.expect_value(t, text_of(sink, event.summary_string_id), "checkpoint")
	// The envelope timestamp is honoured, so it sits in the right place.
	testing.expect_value(t, event.wall_time_ns, i64(5))
}

// Malformed input.

@(test)
a_malformed_line_does_not_discard_the_session :: proc(t: ^testing.T) {
	// A truncated final line is the common case, and refusing the whole log for
	// it would discard a session that is otherwise entirely readable.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"before"}`, "\n",
			`{"type":"message","t":2,`, "\n",
			`not json at all`, "\n",
			`[1,2,3]`, "\n",
			`{"no_type_field":true}`, "\n",
			`{"type":"message","t":3,"role":"user","text":"after"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, count_kind(sink, .User_Message), 2)
	testing.expect_value(t, sink.report.ignored_records, 4)
	testing.expect(t, sink.report.warnings[int(codec.Warning_Category.Malformed_Record)] >= 4)
}

@(test)
blank_lines_are_not_records :: proc(t: ^testing.T) {
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n\n",
			`{"type":"message","t":1,"role":"user","text":"a"}`, "\n",
			"   \n\n",
			`{"type":"message","t":2,"role":"user","text":"b"}`, "\n\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, sink.report.source_records, 2)
	testing.expect_value(t, sink.report.ignored_records, 0)
	testing.expect_value(t, len(sink.events), 2)
}

@(test)
carriage_returns_are_tolerated :: proc(t: ^testing.T) {
	// A log written on Windows is still a log.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\r\n", `{"type":"message","t":1,"role":"user","text":"a"}`, "\r\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)
	testing.expect_value(t, len(sink.events), 1)
}

@(test)
a_record_without_a_timestamp_is_counted_not_invented :: proc(t: ^testing.T) {
	// docs/03: an absent timestamp is recorded as absent. Inventing one would
	// place an event at a time it did not occur.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{HEADER, "\n", `{"type":"message","role":"user","text":"when?"}`, "\n"},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, sink.report.absent_timestamps, 1)
	testing.expect(t, .Has_Wall_Time not_in sink.events[0].flags)
}

// Provenance and invariants.

@(test)
every_event_carries_its_source_record :: proc(t: ^testing.T) {
	// docs/03 requires provenance on every event, so a reader can find the
	// source record that produced it.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"a"}`, "\n",
			`{"type":"message","t":2,"role":"user","text":"b"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	for event, index in sink.events {
		testing.expect_value(t, event.source.importer_id, sink.importer_id)
		testing.expectf(
			t,
			event.source.record_number == u64(index + 1),
			"event %d should name record %d",
			index,
			index + 1,
		)
	}
}

@(test)
an_imported_log_satisfies_the_invariants :: proc(t: ^testing.T) {
	// Everything at once, which is what a real session looks like.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			`{"type":"session","nsl_version":1,"started_at":1000}`, "\n",
			`{"type":"message","t":1100,"role":"user","text":"fix it","goal":true}`, "\n",
			`{"type":"tool_call","t":1200,"id":"c1","tool":"edit","arguments":{"path":"a.odin"}}`, "\n",
			`{"type":"file","t":1300,"op":"modify","path":"a.odin","before":"x\n","after":"y\n"}`, "\n",
			`{"type":"tool_result","t":1400,"id":"c1","status":"ok","content":"done"}`, "\n",
			`{"type":"command","t":1500,"command":"odin test","exit":0,"output":"ok"}`, "\n",
			`{"type":"test","t":1600,"name":"t1","suite":"s","status":"pass"}`, "\n",
			`{"type":"unknown_thing","t":1700}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect(t, core.ok(api.validate_invariants(sink)))
	testing.expect_value(t, count_kind(sink, .Session_Start), 1)
	testing.expect_value(t, sink.report.source_records, 7)
	testing.expect(t, sink.report.canonical_events > 7, "commands expand to three events")
}

@(test)
inspection_reports_unsupported_types_without_importing :: proc(t: ^testing.T) {
	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"a"}`, "\n",
			`{"type":"checkpoint","t":2}`, "\n",
			`{"type":"checkpoint","t":3}`, "\n",
			`{"type":"telemetry","t":4}`, "\n",
		},
		context.temp_allocator,
	)

	metadata, err := nsl.inspect(transmute([]byte)log, context.temp_allocator)
	defer api.source_metadata_destroy(&metadata)

	testing.expect(t, core.ok(err))
	testing.expect_value(t, metadata.record_count, 4)
	testing.expect_value(t, metadata.variant, "nsl v1")
	// Named once each, not once per occurrence.
	testing.expect_value(t, len(metadata.unsupported_types), 2)
	testing.expect(t, metadata.expected.conversation)
	testing.expect(t, metadata.expected.timestamps)
	testing.expect(t, !metadata.expected.file_mutations)
}

@(test)
a_long_message_gets_a_bounded_single_line_summary :: proc(t: ^testing.T) {
	// A summary spanning lines renders as one run-on label in the timeline, and
	// an unbounded one fills the string table with whole conversations.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	long := strings.repeat("a", 500, context.temp_allocator)
	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"first line\nsecond line"}`, "\n",
			`{"type":"message","t":2,"role":"user","text":"`, long, `"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect_value(t, text_of(sink, sink.events[0].summary_string_id), "first line")
	testing.expect_value(t, len(text_of(sink, sink.events[1].summary_string_id)), nsl.SUMMARY_LENGTH)

	// The full text is still stored, so nothing is lost by summarising.
	testing.expect_value(t, len(sink.payloads.messages), 2)
	testing.expect(t, sink.payloads.messages[1].text != model.NO_BLOB)
}

@(test)
a_goal_message_is_marked :: proc(t: ^testing.T) {
	// Attempt detection uses goal-bearing messages as boundaries.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"message","t":1,"role":"user","text":"do it","goal":true}`, "\n",
			`{"type":"message","t":2,"role":"user","text":"thanks"}`, "\n",
			`{"type":"message","t":3,"role":"assistant","text":"ok","goal":true}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	testing.expect(t, sink.payloads.messages[0].goal_bearing)
	testing.expect(t, !sink.payloads.messages[1].goal_bearing)
	// An assistant message does not state the user's goal.
	testing.expect(t, !sink.payloads.messages[2].goal_bearing)
}

@(test)
entities_are_shared_across_records :: proc(t: ^testing.T) {
	// A session that touches one file forty times must produce one path entity,
	// or the repository map would show forty nodes for one file.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	log := strings.concatenate(
		{
			HEADER, "\n",
			`{"type":"file","t":1,"op":"read","path":"a.odin"}`, "\n",
			`{"type":"file","t":2,"op":"modify","path":"a.odin","after":"x"}`, "\n",
			`{"type":"diagnostic","t":3,"severity":"error","path":"a.odin","message":"m"}`, "\n",
		},
		context.temp_allocator,
	)

	sink := run(t, &harness, log)

	paths := 0
	for entity in sink.entities {
		if entity.kind == .Path {
			paths += 1
		}
	}
	testing.expect_value(t, paths, 1)
}

@(test)
parsing_memory_does_not_grow_with_the_log :: proc(t: ^testing.T) {
	// docs/05: "the parser is streaming. It must not load the entire source log
	// into memory."
	//
	// The failure this guards against is invisible to every other test here:
	// records still map correctly, counts still come out right, and the trace is
	// byte-identical. Only peak parsing memory differs, which is why the sink
	// records it. Comparing two sizes of the same log is what makes a retaining
	// parser observable — its high-water mark tracks the file.
	build :: proc(records: int) -> string {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, HEADER)
		strings.write_byte(&builder, '\n')
		padding := strings.repeat("x", 512, context.temp_allocator)
		for index in 0 ..< records {
			// Padded, so retaining every record dwarfs the fixed block size.
			fmt.sbprintfln(
				&builder,
				`{{"type":"message","t":%d,"role":"user","text":"%s"}}`,
				index + 1,
				padding,
			)
		}
		return strings.to_string(builder)
	}

	measure :: proc(t: ^testing.T, log: string) -> u64 {
		harness: Harness
		begin(&harness)
		defer finish(&harness)

		err := nsl.import_source(transmute([]byte)log, &harness.sink, api.Options{})
		testing.expect(t, core.ok(err))
		return harness.sink.report.peak_parse_bytes
	}

	small := measure(t, build(100))
	large := measure(t, build(4_000))

	// Forty times the records, and forty times the bytes. A parser that released
	// each record needs room for one; a parser that retained them needs room for
	// all of them, and the two are orders of magnitude apart.
	testing.expectf(
		t,
		large == small,
		"parsing 40x the records reserved %d bytes against %d: memory must track the largest record, not the log",
		large,
		small,
	)
}

@(test)
invalid_utf8_is_refused_before_the_json_parser :: proc(t: ^testing.T) {
	// A hostile log containing raw invalid UTF-8 aborted the process before this
	// check existed. Odin's JSON string decoder sizes its output buffer from the
	// input length, but an invalid byte decodes to RUNE_ERROR and re-encodes to
	// three bytes, so a single 0xFF writes past the end and traps.
	//
	// docs/08 requires UTF-8 validation at the boundary regardless. Keeping the
	// test at this level means an upstream repair cannot quietly remove the
	// protection without something noticing.
	harness: Harness
	begin(&harness)
	defer finish(&harness)

	hostile := []string {
		"\xff\xfe",             // never valid
		"\xc0\x80",             // overlong NUL
		"\xed\xa0\x80",         // a surrogate half
		"\xe2\x82",             // truncated three-byte sequence
		"\xf0\x9f",             // truncated four-byte sequence
	}

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, HEADER)
	strings.write_byte(&builder, '\n')
	for bytes, index in hostile {
		fmt.sbprintfln(
			&builder,
			`{{"type":"message","t":%d,"role":"user","text":"bad %s here"}}`,
			index + 1,
			bytes,
		)
	}
	// A valid record after the damage: the import must continue rather than
	// discard a session that is otherwise readable.
	fmt.sbprintfln(
		&builder,
		`{{"type":"message","t":99,"role":"user","text":"still readable"}}`,
	)

	sink := run(t, &harness, strings.to_string(builder))

	// Every malformed record counted, none carried into the trace, and the
	// valid one kept.
	testing.expect_value(t, sink.report.ignored_records, u64(len(hostile)))
	testing.expect_value(t, len(sink.events), 1)
	testing.expect_value(t, text_of(sink, sink.events[0].summary_string_id), "still readable")
	testing.expect(
		t,
		sink.report.warnings[int(codec.Warning_Category.Malformed_Record)] >= u32(len(hostile)),
		"each rejected record must be reported",
	)
}
