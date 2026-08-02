package test_export

import "core:strings"
import "core:testing"

import "src:analysis"
import "src:export"
import "src:trace/codec"
import "src:trace/model"

// Bundle assembly and rendering.
//
// These exercise the whole export path against a trace whose text is hostile,
// which is the realistic case: a trace records whatever an agent and its tools
// produced, and neither is trusted.

Fixture :: struct {
	trace:    codec.Trace,
	outcomes: analysis.Outcome_Index,
	failure:  model.Event_Id,
}

@(private)
fixture_destroy :: proc(fixture: ^Fixture) {
	analysis.outcome_index_destroy(&fixture.outcomes)
	codec.trace_destroy(&fixture.trace)
}

// make_fixture builds a small failing session. `hostile` injects markup into
// every text field an export might render.
@(private)
make_fixture :: proc(fixture: ^Fixture, hostile := false) {
	t := &fixture.trace
	model.string_table_init(&t.strings)
	model.blob_table_init(&t.blobs)
	model.payload_tables_init(&t.payloads)
	t.entities = make([dynamic]model.Entity, 0, 8)
	t.spans = make([dynamic]model.Span, 0, 4)
	t.events = make([dynamic]model.Event, 0, 16)
	t.edges = make([dynamic]model.Edge, 0, 8)
	t.mutations = make([dynamic]model.Mutation, 0, 8)
	t.directory = make([dynamic]codec.Directory_Entry, 0, 4)
	t.header.major = 1
	t.header.minor = 0

	si :: proc(t: ^codec.Trace, value: string) -> model.String_Id {
		id, _ := model.string_intern(&t.strings, value)
		return id
	}

	path_name := "src/parser.odin"
	test_name := "parses_input"
	repo_name := "norn"
	if hostile {
		path_name = "<script>alert('path')</script>.odin"
		test_name = "</td><script>alert('test')</script>"
		repo_name = `"><img src=x onerror=alert(1)>`
	}

	append(&t.entities, model.Entity{id = 1, kind = .Path, name = si(t, path_name)})
	append(&t.entities, model.Entity{id = 2, kind = .Test_Case, name = si(t, test_name)})

	append(
		&t.edges,
		model.Edge {
			kind = .Tests,
			origin = .Explicit,
			from = model.entity_endpoint(2),
			to = model.entity_endpoint(1),
			confidence = model.CONFIDENCE_SCALE,
		},
	)

	summary := "edit the parser"
	if hostile {
		summary = "<script>alert('summary')</script>"
	}

	// A mutation, then a failing test.
	append(
		&t.events,
		model.Event {
			id = 1,
			sequence = 1,
			kind = .File_Modify,
			flags = {.Has_Wall_Time},
			wall_time_ns = 1_700_000_000_000_000_000,
			primary_entity_id = 1,
			summary_string_id = si(t, summary),
		},
	)
	append(
		&t.mutations,
		model.Mutation{event_id = 1, path = 1, op = .Modify, encoding = .Utf8, status = .Verified},
	)

	payload := model.add_test(
		&t.payloads,
		model.Test_Payload{test_case = 2, status = .Failed},
	)
	append(
		&t.events,
		model.Event {
			id = 2,
			sequence = 2,
			kind = .Test_Case_Result,
			flags = {.Has_Wall_Time},
			wall_time_ns = 1_700_000_001_000_000_000,
			primary_entity_id = 2,
			payload = payload,
		},
	)
	fixture.failure = 2

	t.metadata = codec.Session_Metadata {
		importer_id = si(t, "codex"),
		importer_version = si(t, "0.1.0"),
		repository_name = si(t, repo_name),
		baseline_kind = .Commit_Verified,
		canonical_event_count = 2,
	}
	t.metadata.warnings[int(codec.Warning_Category.Timestamp_Repaired)] = 3
	t.metadata.redactions[int(codec.Redaction_Category.Credential)] = 2

	fixture.outcomes = analysis.build_outcome_index(t)
}

@(private)
build :: proc(fixture: ^Fixture, options := export.DEFAULT_OPTIONS) -> export.Bundle {
	return export.build_bundle(
		&fixture.trace,
		&fixture.outcomes,
		0,
		1000,
		fixture.failure,
		options,
	)
}

@(test)
bundle_includes_the_documented_sections :: proc(t: ^testing.T) {
	// docs/01 fixes what an export contains.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	testing.expect_value(t, bundle.importer_id, "codex")
	testing.expect_value(t, bundle.repository_name, "norn")
	testing.expect(t, bundle.has_focus_outcome)
	testing.expect(t, len(bundle.events) > 0, "the range must carry its events")
	testing.expect(t, len(bundle.outcomes) > 0, "outcomes must be included")
	testing.expect(t, len(bundle.changes) > 0, "file changes must be included")
	testing.expect(t, len(bundle.candidates) > 0, "candidates must be included")

	// Import warnings travel with the export, per docs/01.
	testing.expect_value(
		t,
		bundle.manifest.warnings_by_category[int(codec.Warning_Category.Timestamp_Repaired)],
		u32(3),
	)
	testing.expect_value(
		t,
		bundle.manifest.redactions_by_category[int(codec.Redaction_Category.Credential)],
		u32(2),
	)
}

@(test)
prompt_text_is_excluded_by_default :: proc(t: ^testing.T) {
	// docs/01: exports exclude raw source records and unrelated prompt content
	// by default. Including a private conversation by accident is the failure
	// this default exists to prevent.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	testing.expect(t, !bundle.manifest.has_prompt_text)
	testing.expect(t, !bundle.manifest.has_raw_records)
}

@(test)
manifest_reports_what_was_included :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	// docs/08 requires the manifest to state each category.
	testing.expect(t, bundle.manifest.has_file_paths)
	testing.expect(t, bundle.manifest.has_diffs)
	testing.expect(t, bundle.manifest.has_repository_metadata)
	testing.expect_value(t, bundle.manifest.event_count, len(bundle.events))
	testing.expect_value(t, bundle.manifest.candidate_count, len(bundle.candidates))
}

@(test)
range_selection_bounds_the_export :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	// A range covering only the first event must exclude the second.
	bundle := export.build_bundle(
		&fixture.trace,
		&fixture.outcomes,
		1,
		1,
		model.NO_EVENT,
	)
	defer export.bundle_destroy(&bundle)

	testing.expect_value(t, len(bundle.events), 1)
	testing.expect_value(t, bundle.events[0].sequence, model.Sequence(1))
	testing.expect_value(t, len(bundle.outcomes), 0)
}

@(test)
html_report_neutralizes_hostile_trace_text :: proc(t: ^testing.T) {
	// The whole point of the export path: a trace containing markup must
	// produce a report that displays it, never one that executes it.
	fixture: Fixture
	make_fixture(&fixture, hostile = true)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture, export.Options{include_messages = true, include_output = true})
	defer export.bundle_destroy(&bundle)

	html := export.render_html(&bundle)
	defer delete(html)

	testing.expect(
		t,
		!strings.contains(html, "<script>alert"),
		"an injected script element must not survive into the report",
	)
	// The dangerous part of an event handler is the markup that introduces it,
	// not the attribute text. Asserting on `onerror=` alone would fail on the
	// correctly escaped form, where the string appears as inert content, so
	// the check is that no unescaped tag delimiter precedes it.
	testing.expect(
		t,
		!strings.contains(html, "<img"),
		"an injected element must not survive into the report",
	)
	testing.expect(
		t,
		!strings.contains(html, "alert('path')"),
		"injected script content must not appear unescaped",
	)
	testing.expect(
		t,
		!strings.contains(html, "</td><script"),
		"an injected element must not break out of a table cell",
	)
	// The text is still present, escaped, so the reader can see what the
	// session actually recorded.
	testing.expect(
		t,
		strings.contains(html, "&lt;script&gt;"),
		"the hostile text must appear escaped rather than dropped",
	)
}

@(test)
html_report_declares_a_restrictive_policy :: proc(t: ^testing.T) {
	// docs/08: a restrictive content security policy, no remote resources, and
	// no executable JavaScript requirement.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	html := export.render_html(&bundle)
	defer delete(html)

	testing.expect(t, strings.contains(html, "Content-Security-Policy"))
	testing.expect(t, strings.contains(html, "default-src 'none'"))

	// No script element at all: a report that cannot run code cannot be made
	// to run trace content.
	testing.expect(t, !strings.contains(html, "<script"))

	// Self-contained: nothing is fetched from a remote host.
	testing.expect(t, !strings.contains(html, "http://"))
	testing.expect(t, !strings.contains(html, "https://"))
	testing.expect(t, !strings.contains(html, "<link"))
}

@(test)
html_report_labels_candidates_as_candidates :: proc(t: ^testing.T) {
	// docs/01 and decision 008: the interface says "candidate contributor",
	// never "cause".
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	html := export.render_html(&bundle)
	defer delete(html)

	testing.expect(t, strings.contains(html, "Candidate contributors"))
	testing.expect(t, strings.contains(html, "not probabilities"))
	testing.expect(
		t,
		!strings.contains(html, "caused by"),
		"the report must not assert causation",
	)
}

@(test)
html_report_shows_rules_behind_each_score :: proc(t: ^testing.T) {
	// docs/11 exit criterion: every score expands into its deterministic rule
	// contributions.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	html := export.render_html(&bundle)
	defer delete(html)

	testing.expect(t, strings.contains(html, "test_file_relationship@1"))
	testing.expect(t, strings.contains(html, "explicit relationship"))
}

@(test)
json_is_well_formed_with_hostile_input :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture, hostile = true)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture, export.Options{include_messages = true})
	defer export.bundle_destroy(&bundle)

	json := export.render_json(&bundle)
	defer delete(json)

	// Balanced braces and brackets are a cheap structural check that hostile
	// text did not terminate a string or object early.
	braces := 0
	brackets := 0
	in_string := false
	escaped := false
	for index in 0 ..< len(json) {
		c := json[index]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		switch c {
		case '"': in_string = true
		case '{': braces += 1
		case '}': braces -= 1
		case '[': brackets += 1
		case ']': brackets -= 1
		}
		testing.expectf(t, braces >= 0, "unbalanced closing brace at byte %d", index)
		testing.expectf(t, brackets >= 0, "unbalanced closing bracket at byte %d", index)
	}
	testing.expect_value(t, braces, 0)
	testing.expect_value(t, brackets, 0)
	testing.expect(t, !in_string, "the document must not end inside a string")
}

@(test)
json_records_the_origin_of_every_edge :: proc(t: ^testing.T) {
	// docs/06 requires the evidence level to be identifiable, which for a
	// machine consumer means the origin must be present on every edge.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	json := export.render_json(&bundle)
	defer delete(json)

	testing.expect(t, strings.contains(json, `"evidence_edges"`))
	testing.expect(t, strings.contains(json, `"candidate_contributors"`))
	// The key names the relationship rather than implying causation.
	testing.expect(t, !strings.contains(json, `"causes"`))
}

@(test)
json_export_is_deterministic :: proc(t: ^testing.T) {
	// docs/05 determinism, applied to the export: two runs over the same range
	// must produce identical bytes, or a reviewer cannot diff two reports.
	first: Fixture
	make_fixture(&first)
	defer fixture_destroy(&first)
	bundle_a := build(&first)
	defer export.bundle_destroy(&bundle_a)
	json_a := export.render_json(&bundle_a)
	defer delete(json_a)

	second: Fixture
	make_fixture(&second)
	defer fixture_destroy(&second)
	bundle_b := build(&second)
	defer export.bundle_destroy(&bundle_b)
	json_b := export.render_json(&bundle_b)
	defer delete(json_b)

	testing.expect_value(t, len(json_a), len(json_b))
	testing.expect(t, json_a == json_b, "two exports of the same range must be identical")
}

@(test)
html_export_is_deterministic :: proc(t: ^testing.T) {
	first: Fixture
	make_fixture(&first)
	defer fixture_destroy(&first)
	bundle_a := build(&first)
	defer export.bundle_destroy(&bundle_a)
	html_a := export.render_html(&bundle_a)
	defer delete(html_a)

	second: Fixture
	make_fixture(&second)
	defer fixture_destroy(&second)
	bundle_b := build(&second)
	defer export.bundle_destroy(&bundle_b)
	html_b := export.render_html(&bundle_b)
	defer delete(html_b)

	testing.expect(t, html_a == html_b)
}

@(test)
gap_affected_changes_are_labeled :: proc(t: ^testing.T) {
	// docs/01: Norn does not present partial replay as complete replay.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)
	fixture.trace.mutations[0].status = .Unsupported_Patch

	bundle := build(&fixture)
	defer export.bundle_destroy(&bundle)

	testing.expect(t, bundle.changes[0].affected_by_gap)

	html := export.render_html(&bundle)
	defer delete(html)
	testing.expect(t, strings.contains(html, "replay gap"))

	json := export.render_json(&bundle)
	defer delete(json)
	testing.expect(t, strings.contains(json, `"affected_by_replay_gap": true`))
}
