package test_importers

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "src:core"
import api "src:importers/api"
import "src:trace/codec"
import "src:trace/model"

// The import pipeline.
//
// docs/05 fixes the stage order, and docs/11 makes one exit criterion explicit:
// "import never writes a complete-looking destination after failure." These
// tests drive the coordinator with a synthetic adapter so the stages can be
// failed one at a time — no real provider log is involved, and per docs/05 the
// fixtures here carry no credentials, prompts, usernames, or home paths.

@(private)
scratch_path :: proc(t: ^testing.T, name: string) -> string {
	directory, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no temporary directory available")
	}
	return strings.concatenate({directory, "/norn-test-", name, ".norn"}, context.temp_allocator)
}

// A synthetic adapter. Two records, one of which mutates a file.
@(private)
good_import :: proc(source: []byte, sink: ^api.Sink, options: api.Options) -> core.Error {
	api.declare_capability(sink, .Conversation_Text)

	actor := api.add_entity(sink, .Actor_Agent, "assistant", "")
	path := api.add_entity(sink, .Path, "src/main.odin", "")

	sink.report.source_records = 2

	api.add_event(
		sink,
		api.Event_Input {
			kind = .Agent_Message,
			wall_time_ns = 1_000_000_000,
			has_wall_time = true,
			actor = actor,
			summary = "thinking about it",
			source_type = "message",
			record_number = 0,
		},
	)

	event := api.add_event(
		sink,
		api.Event_Input {
			kind = .File_Modify,
			wall_time_ns = 2_000_000_000,
			has_wall_time = true,
			actor = actor,
			primary = path,
			summary = "edit src/main.odin",
			source_type = "tool_use",
			record_number = 1,
		},
	)

	api.add_mutation(
		sink,
		model.Mutation {
			event_id = event,
			op = .Modify,
			path = path,
			status = .Reconstructed_Unverified,
		},
	)

	return nil
}

@(private)
good_inspect :: proc(
	source: []byte,
	allocator: mem.Allocator,
) -> (
	api.Source_Metadata,
	core.Error,
) {
	metadata := api.Source_Metadata {
		record_count = 2,
		size_bytes   = u64(len(source)),
		variant      = "synthetic v1",
	}
	metadata.unsupported_types = make([dynamic]string, 0, 1, allocator)
	append(&metadata.unsupported_types, "checkpoint")
	metadata.expected.timestamps = true
	metadata.expected.conversation = true
	return metadata, nil
}

@(private)
good_adapter :: proc() -> api.Importer {
	return api.Importer {
		id = "synthetic",
		version = "1.0.0",
		inspect = good_inspect,
		import_source = good_import,
	}
}

@(private)
test_identity :: proc() -> api.Session_Identity {
	return api.Session_Identity {
		repository_name = "norn",
		repository_path = "/repos/norn",
		version_control = .Repository,
		start_commit = "3c146e0a5f2b1d8e9c4a7f6b2d1e8c9a4f7b6d2e",
		branch = "master",
		case_sensitive = true,
	}
}

@(test)
a_successful_import_publishes_a_readable_trace :: proc(t: ^testing.T) {
	// The whole pipeline: the destination must open, validate, and hold what the
	// adapter described.
	destination := scratch_path(t, "success")
	defer os.remove(destination)

	outcome, err := import_source_checked(t, good_adapter(), destination)

	testing.expect(t, core.ok(err))
	testing.expect_value(t, outcome.destination, destination)
	testing.expect(t, outcome.trace_bytes > 0, "the published trace must have a size")
	testing.expect_value(t, outcome.report.canonical_events, 2)
	testing.expect_value(t, outcome.report.source_records, 2)

	data, read_err := os.read_entire_file_from_path(destination, context.temp_allocator)
	testing.expect(t, read_err == nil, "the destination must exist")

	trace, open_err := codec.open_trace(data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&trace)

	testing.expect(t, core.ok(open_err), "the published trace must open")
	testing.expect_value(t, len(trace.events), 2)
	testing.expect_value(t, len(trace.mutations), 1)
	testing.expect_value(t, trace.metadata.canonical_event_count, 2)
}

@(private)
import_source_checked :: proc(
	t: ^testing.T,
	importer: api.Importer,
	destination: string,
) -> (
	api.Import_Outcome,
	core.Error,
) {
	return api.import_source(
		importer,
		transmute([]byte)string("synthetic source"),
		destination,
		test_identity(),
		api.Options{home_prefix = "/home/nobody"},
	)
}

@(test)
identity_reaches_the_trace_metadata :: proc(t: ^testing.T) {
	// docs/05 lists what the importer records about the repository; the trace is
	// where a later session reads it back.
	destination := scratch_path(t, "identity")
	defer os.remove(destination)

	_, err := import_source_checked(t, good_adapter(), destination)
	testing.expect(t, core.ok(err))

	data, _ := os.read_entire_file_from_path(destination, context.temp_allocator)
	trace, open_err := codec.open_trace(data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&trace)
	testing.expect(t, core.ok(open_err))

	name, _ := model.string_get(&trace.strings, trace.metadata.repository_name)
	branch, _ := model.string_get(&trace.strings, trace.metadata.branch)
	commit, _ := model.string_get(&trace.strings, trace.metadata.start_commit)

	testing.expect_value(t, name, "norn")
	testing.expect_value(t, branch, "master")
	testing.expect_value(t, commit, "3c146e0a5f2b1d8e9c4a7f6b2d1e8c9a4f7b6d2e")
	testing.expect_value(t, trace.metadata.version_control, codec.Version_Control.Git)
	testing.expect(t, trace.metadata.case_sensitive_paths)
}

@(test)
the_session_extent_comes_from_the_events :: proc(t: ^testing.T) {
	// Not from a clock read during import: the trace describes the session, not
	// when it happened to be converted.
	destination := scratch_path(t, "extent")
	defer os.remove(destination)

	_, err := import_source_checked(t, good_adapter(), destination)
	testing.expect(t, core.ok(err))

	data, _ := os.read_entire_file_from_path(destination, context.temp_allocator)
	trace, open_err := codec.open_trace(data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&trace)
	testing.expect(t, core.ok(open_err))

	testing.expect_value(t, trace.metadata.session_start_ns, i64(1_000_000_000))
	testing.expect_value(t, trace.metadata.session_end_ns, i64(2_000_000_000))
}

@(private)
failing_import :: proc(source: []byte, sink: ^api.Sink, options: api.Options) -> core.Error {
	// Records some work first, so the failure is not simply an empty sink.
	api.add_event(sink, api.Event_Input{kind = .User_Message, summary = "partial"})
	return core.err_make(.Malformed_Container, "the source ended mid-record")
}

@(test)
an_adapter_failure_leaves_no_destination :: proc(t: ^testing.T) {
	// docs/11: "import never writes a complete-looking destination after
	// failure." A half-written trace that opens is worse than no trace, because
	// a user would debug against a session that never happened.
	destination := scratch_path(t, "adapter-failure")
	defer os.remove(destination)

	importer := good_adapter()
	importer.import_source = failing_import

	outcome, err := import_source_checked(t, importer, destination)

	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Malformed_Container)
	testing.expect_value(t, outcome.destination, "")
	testing.expect(t, !os.exists(destination), "no destination may remain after a failure")
}

@(private)
invariant_breaking_import :: proc(
	source: []byte,
	sink: ^api.Sink,
	options: api.Options,
) -> core.Error {
	// A mutation naming an event that does not exist. The sink assigns event
	// identifiers, so an adapter cannot break ordering — but it can still point a
	// mutation at nothing.
	api.add_event(sink, api.Event_Input{kind = .File_Modify, summary = "edit"})
	api.add_mutation(
		sink,
		model.Mutation{event_id = model.Event_Id(99), op = .Modify, status = .Missing_Baseline},
	)
	return nil
}

@(test)
a_broken_invariant_fails_before_the_writer_runs :: proc(t: ^testing.T) {
	// Catching it here names the adapter, rather than reporting a corrupt trace
	// after the writer has already produced bytes.
	destination := scratch_path(t, "invariant")
	defer os.remove(destination)

	importer := good_adapter()
	importer.import_source = invariant_breaking_import

	_, err := import_source_checked(t, importer, destination)

	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invalid_Reference)
	testing.expect(t, !os.exists(destination), "no destination may remain after a failure")
}

@(test)
an_adapter_that_cannot_import_is_refused :: proc(t: ^testing.T) {
	destination := scratch_path(t, "no-import")
	defer os.remove(destination)

	importer := good_adapter()
	importer.import_source = nil

	_, err := import_source_checked(t, importer, destination)

	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invalid_Argument)
	testing.expect(t, !os.exists(destination))
}

@(private)
redacting_import :: proc(source: []byte, sink: ^api.Sink, options: api.Options) -> core.Error {
	api.add_event(
		sink,
		api.Event_Input {
			kind = .Command_Start,
			summary = "reading /home/nobody/projects/thing/main.odin",
		},
	)
	return nil
}

@(test)
redaction_runs_before_anything_is_written :: proc(t: ^testing.T) {
	// docs/08: redaction occurs during import before writing the destination
	// trace. A secret that reaches the writer is a secret in the artifact, and no
	// later filtering removes it from a file already on disk.
	destination := scratch_path(t, "redaction")
	defer os.remove(destination)

	importer := good_adapter()
	importer.import_source = redacting_import

	outcome, err := import_source_checked(t, importer, destination)
	testing.expect(t, core.ok(err))

	data, _ := os.read_entire_file_from_path(destination, context.temp_allocator)
	testing.expect(
		t,
		!strings.contains(string(data), "/home/nobody"),
		"the home prefix must not appear anywhere in the file",
	)

	testing.expect(
		t,
		outcome.report.redactions[int(codec.Redaction_Category.Home_Path_Prefix)] > 0,
		"the report must count what was replaced",
	)
}

@(test)
the_repository_path_is_redacted_in_metadata :: proc(t: ^testing.T) {
	// docs/05: absolute source paths are retained only in redacted provenance
	// metadata. The path goes through the sink like any other source string.
	destination := scratch_path(t, "repository-path")
	defer os.remove(destination)

	identity := test_identity()
	identity.repository_path = "/home/nobody/projects/norn"

	_, err := api.import_source(
		good_adapter(),
		transmute([]byte)string("synthetic source"),
		destination,
		identity,
		api.Options{home_prefix = "/home/nobody"},
	)
	testing.expect(t, core.ok(err))

	data, _ := os.read_entire_file_from_path(destination, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), "/home/nobody"))

	trace, open_err := codec.open_trace(data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&trace)
	testing.expect(t, core.ok(open_err))

	path, _ := model.string_get(&trace.strings, trace.metadata.repository_path)
	testing.expect(t, strings.contains(path, "projects/norn"), "the tail must survive")
	testing.expect(t, api.contains_marker(path), "the prefix must be marked")
}

@(test)
two_imports_of_one_source_produce_equal_content :: proc(t: ^testing.T) {
	// docs/05 requires determinism, and excludes the session identity from the
	// canonical-content digest — so two imports differ only in that identifier.
	first := scratch_path(t, "determinism-a")
	second := scratch_path(t, "determinism-b")
	defer os.remove(first)
	defer os.remove(second)

	_, first_err := import_source_checked(t, good_adapter(), first)
	_, second_err := import_source_checked(t, good_adapter(), second)
	testing.expect(t, core.ok(first_err))
	testing.expect(t, core.ok(second_err))

	first_data, _ := os.read_entire_file_from_path(first, context.temp_allocator)
	second_data, _ := os.read_entire_file_from_path(second, context.temp_allocator)

	a, a_err := codec.open_trace(first_data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&a)
	b, b_err := codec.open_trace(second_data, core.DEFAULT_LIMITS, context.temp_allocator)
	defer codec.trace_destroy(&b)
	testing.expect(t, core.ok(a_err))
	testing.expect(t, core.ok(b_err))

	// The identity differs; everything the digest covers does not.
	testing.expect(t, a.header.session_id != b.header.session_id, "each import is its own session")

	testing.expect_value(t, len(a.events), len(b.events))
	for event, index in a.events {
		other := b.events[index]
		testing.expect_value(t, event.id, other.id)
		testing.expect_value(t, event.sequence, other.sequence)
		testing.expect_value(t, event.kind, other.kind)
		testing.expect_value(t, event.wall_time_ns, other.wall_time_ns)
		testing.expect_value(t, event.summary_string_id, other.summary_string_id)
	}
}

@(test)
inspection_reports_without_writing :: proc(t: ^testing.T) {
	// docs/01: import "shows the detected session metadata, and reports any
	// unsupported record types before writing output."
	metadata, err := api.inspect_source(
		good_adapter(),
		transmute([]byte)string("synthetic source"),
		context.temp_allocator,
	)
	defer api.source_metadata_destroy(&metadata)

	testing.expect(t, core.ok(err))
	testing.expect_value(t, metadata.record_count, 2)
	testing.expect_value(t, metadata.variant, "synthetic v1")
	testing.expect_value(t, len(metadata.unsupported_types), 1)
	testing.expect_value(t, metadata.unsupported_types[0], "checkpoint")
}

@(test)
an_adapter_that_cannot_inspect_says_so :: proc(t: ^testing.T) {
	importer := good_adapter()
	importer.inspect = nil

	_, err := api.inspect_source(importer, {}, context.temp_allocator)

	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Unsupported_Feature)
}

@(test)
the_report_states_counts_never_values :: proc(t: ^testing.T) {
	// docs/08: reports "list rule identifiers and counts, never matched values."
	destination := scratch_path(t, "report")
	defer os.remove(destination)

	importer := good_adapter()
	importer.import_source = redacting_import

	outcome, err := import_source_checked(t, importer, destination)
	testing.expect(t, core.ok(err))

	text := api.format_report(&outcome, context.temp_allocator)

	testing.expect(t, strings.contains(text, "canonical events"))
	testing.expect(t, strings.contains(text, "timestamps:"))
	testing.expect(t, strings.contains(text, "redactions:"))
	testing.expect(
		t,
		!strings.contains(text, "/home/nobody"),
		"the report must never restate a redacted value",
	)
}

@(test)
the_report_reads_the_same_for_an_unredacted_import :: proc(t: ^testing.T) {
	// A section for a count of zero would be noise, and a user scanning a report
	// should be able to tell "nothing was redacted" from a missing section.
	destination := scratch_path(t, "clean-report")
	defer os.remove(destination)

	outcome, err := import_source_checked(t, good_adapter(), destination)
	testing.expect(t, core.ok(err))

	text := api.format_report(&outcome, context.temp_allocator)

	testing.expect(t, !strings.contains(text, "redactions:"))
	testing.expect(t, strings.contains(text, "mutations:"))
	testing.expect(t, strings.contains(text, "1 partial") || strings.contains(text, "replayable"))
}
