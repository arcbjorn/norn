package test_analysis

import "core:testing"

import "src:analysis"
import "src:core"
import "src:trace/model"

// Search and filtering.
//
// docs/01 lists what search covers and states the rule the design turns on:
// "a hidden filter must never explain an apparently missing event." A user who
// cannot find something they know is there must be able to see why, which is
// why every result carries the field that matched and every query reports what
// each filter removed.
//
// The failure mode these guard against is quiet: a matcher that misses a field
// returns fewer rows, not an error, and the user concludes the event is not in
// the trace.

@(private)
run_query :: proc(
	t: ^testing.T,
	builder: ^Builder,
	query: analysis.Query,
) -> analysis.Results {
	results, err := analysis.search(&builder.trace, query)
	testing.expect(t, core.ok(err), "a query must not fail")
	return results
}

@(private)
matched_events :: proc(results: ^analysis.Results) -> []model.Event_Id {
	ids := make([dynamic]model.Event_Id, 0, len(results.matches), context.temp_allocator)
	for match in results.matches {
		append(&ids, match.event)
	}
	return ids[:]
}

@(private)
contains_event :: proc(results: ^analysis.Results, id: model.Event_Id) -> bool {
	for match in results.matches {
		if match.event == id {
			return true
		}
	}
	return false
}

@(private)
field_for :: proc(results: ^analysis.Results, id: model.Event_Id) -> analysis.Field {
	for match in results.matches {
		if match.event == id {
			return match.field
		}
	}
	return .None
}

@(test)
search_finds_text_in_a_summary :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	wanted := add_message(&builder, .User_Message, "the timeline drops events")
	add_message(&builder, .Agent_Message, "looking at the reader")

	query := analysis.query_default()
	query.text = "drops"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, contains_event(&results, wanted))
}

@(test)
search_is_case_insensitive :: proc(t: ^testing.T) {
	// A user typing a query does not know how the trace capitalised it.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	wanted := add_message(&builder, .User_Message, "Fix the Reader Bounds Check")

	for text in ([]string{"reader", "READER", "ReAdEr"}) {
		query := analysis.query_default()
		query.text = text
		results := run_query(t, &builder, query)
		defer analysis.results_destroy(&results)

		testing.expectf(t, contains_event(&results, wanted), "%q should match", text)
	}
}

@(test)
search_finds_a_path :: proc(t: ^testing.T) {
	// docs/01 lists paths among what search covers, and a path is the most
	// common thing a user searches for.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/replay/engine.odin")
	other := add_entity(&builder, .Path, "src/ui/timeline.odin")
	wanted := push_event(&builder, .File_Modify, primary = path, summary = "edit")
	push_event(&builder, .File_Modify, primary = other, summary = "edit")

	query := analysis.query_default()
	query.text = "engine.odin"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, contains_event(&results, wanted))
	testing.expect_value(t, field_for(&results, wanted), analysis.Field.Path)
}

@(test)
search_finds_a_diagnostic_message :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "a.odin")
	wanted := add_diagnostic(&builder, path, 12, "undefined identifier")

	query := analysis.query_default()
	query.text = "undefined"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect(t, contains_event(&results, wanted))
	testing.expect_value(t, field_for(&results, wanted), analysis.Field.Diagnostic_Message)
}

@(test)
search_finds_a_test_name :: proc(t: ^testing.T) {
	// docs/06 makes the test identity the comparability key, so searching for
	// one is how a user navigates to a specific failure.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	test_case := add_entity(&builder, .Test_Case, "rejects_an_absolute_path")
	wanted := add_test_result(&builder, test_case, .Failed)

	query := analysis.query_default()
	query.text = "absolute_path"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect(t, contains_event(&results, wanted))
	testing.expect_value(t, field_for(&results, wanted), analysis.Field.Test_Name)
}

@(test)
search_finds_an_event_by_identifier :: proc(t: ^testing.T) {
	// docs/01 lists event identifiers among what search covers: a user reading
	// an exported report has a number, not a phrase.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add_message(&builder, .User_Message, "first")
	wanted := add_message(&builder, .User_Message, "second")
	add_message(&builder, .User_Message, "third")

	query := analysis.query_default()
	query.text = "2"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect(t, contains_event(&results, wanted))
	testing.expect_value(t, field_for(&results, wanted), analysis.Field.Identifier)
}

@(test)
an_absurd_identifier_does_not_overflow :: proc(t: ^testing.T) {
	// The query is a user string, and docs/08 requires every value derived from
	// untrusted input to be overflow-checked before use.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add_message(&builder, .User_Message, "hello")

	for text in ([]string{"99999999999999999999999999", "18446744073709551616", "0"}) {
		query := analysis.query_default()
		query.text = text
		results := run_query(t, &builder, query)
		defer analysis.results_destroy(&results)
		// No crash and no false match is the whole assertion.
		testing.expect_value(t, len(results.matches), 0)
	}
}

@(test)
a_kind_filter_reports_what_it_removed :: proc(t: ^testing.T) {
	// docs/01: "a hidden filter must never explain an apparently missing
	// event." The count is what lets the UI say so.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "a.odin")
	add_message(&builder, .User_Message, "shared word")
	push_event(&builder, .File_Modify, primary = path, summary = "shared word")

	query := analysis.query_default()
	query.text = "shared"
	query.kinds = {.File}
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, results.excluded_by_kind > 0, "the filter must report its exclusions")
	testing.expect_value(t, analysis.excluded_total(&results), results.excluded_by_kind)
	testing.expect_value(t, analysis.active_filter_count(query), 1)
}

@(test)
filters_are_composable :: proc(t: ^testing.T) {
	// docs/01 shows filters as chips that combine. Each must narrow the result
	// without disabling the others.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	wanted_path := add_entity(&builder, .Path, "target.odin")
	other_path := add_entity(&builder, .Path, "other.odin")

	push_event(&builder, .File_Modify, primary = other_path, summary = "edit")
	wanted := push_event(&builder, .File_Modify, primary = wanted_path, summary = "edit")
	add_message(&builder, .User_Message, "edit")

	query := analysis.query_default()
	query.text = "edit"
	query.kinds = {.File}
	query.path = wanted_path
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, contains_event(&results, wanted))
	testing.expect_value(t, analysis.active_filter_count(query), 2)
	testing.expect(t, results.excluded_by_kind > 0)
	testing.expect(t, results.excluded_by_path > 0)
}

@(test)
a_failed_only_filter_keeps_only_failures :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	passing := add_entity(&builder, .Test_Case, "passes")
	failing := add_entity(&builder, .Test_Case, "fails")
	add_test_result(&builder, passing, .Passed)
	wanted := add_test_result(&builder, failing, .Failed)

	query := analysis.query_default()
	query.failed_only = true
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, contains_event(&results, wanted))
	testing.expect(t, results.excluded_by_outcome > 0)
}

@(test)
a_time_range_excludes_events_outside_it :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	first := add_message(&builder, .User_Message, "match")
	second := add_message(&builder, .User_Message, "match")
	third := add_message(&builder, .User_Message, "match")

	// The builder advances one second per event.
	middle := builder.trace.events[1].wall_time_ns

	query := analysis.query_default()
	query.text = "match"
	query.start_ns = middle
	query.end_ns = middle
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	testing.expect(t, contains_event(&results, second))
	testing.expect(t, !contains_event(&results, first))
	testing.expect(t, !contains_event(&results, third))
	testing.expect_value(t, results.excluded_by_time, 2)
}

@(test)
an_empty_query_with_no_filters_returns_everything :: proc(t: ^testing.T) {
	// A filter-only query is the natural way to browse one family, so blank
	// text must not mean "no results".
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 5 {
		add_message(&builder, .User_Message, "text")
	}

	results := run_query(t, &builder, analysis.query_default())
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 5)
	testing.expect_value(t, analysis.excluded_total(&results), 0)
	testing.expect_value(t, analysis.active_filter_count(analysis.query_default()), 0)
}

@(test)
results_are_bounded_and_say_so :: proc(t: ^testing.T) {
	// A truncated list that did not report the truncation would look like a
	// complete answer, and a user would conclude the rest do not exist.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 50 {
		add_message(&builder, .User_Message, "repeated")
	}

	query := analysis.query_default()
	query.text = "repeated"
	query.limit = 10
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 10)
	testing.expect_value(t, results.truncated, 40)
	testing.expect_value(t, results.examined, 50)
}

@(test)
results_are_in_sequence_order :: proc(t: ^testing.T) {
	// docs/03 makes sequence the authoritative order, and a result list that
	// did not follow it would jump around the timeline as the user steps.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 8 {
		add_message(&builder, .User_Message, "ordered")
	}

	query := analysis.query_default()
	query.text = "ordered"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	previous := model.Sequence(0)
	for match in results.matches {
		testing.expect(t, match.sequence > previous, "matches must be ordered by sequence")
		previous = match.sequence
	}
}

@(test)
a_match_reports_where_it_was_found :: proc(t: ^testing.T) {
	// The offset is what lets the UI highlight the hit rather than the row.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add_message(&builder, .User_Message, "prefix then needle here")

	query := analysis.query_default()
	query.text = "needle"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 1)
	match := results.matches[0]
	testing.expect_value(t, match.offset, 12)
	testing.expect_value(t, match.text, "prefix then needle here")
}

@(test)
a_query_matching_nothing_still_reports_what_it_examined :: proc(t: ^testing.T) {
	// The difference between "nothing matched" and "a filter hid everything" is
	// the whole point of the accounting.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 4 {
		add_message(&builder, .User_Message, "present")
	}

	query := analysis.query_default()
	query.text = "absent"
	results := run_query(t, &builder, query)
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), 0)
	testing.expect_value(t, results.examined, 4)
	// Nothing was filtered: the text simply did not match, and the UI can say
	// exactly that rather than blaming a chip.
	testing.expect_value(t, analysis.excluded_total(&results), 0)
}

@(test)
every_event_kind_belongs_to_a_family :: proc(t: ^testing.T) {
	// A kind mapped to no family would be invisible under every filter, which
	// is the "hidden filter" failure docs/01 forbids.
	for kind in model.Event_Kind {
		family := analysis.kind_family(kind)
		testing.expectf(
			t,
			family in analysis.ALL_KINDS,
			"%v maps outside the filter set",
			kind,
		)
	}
}

@(test)
the_default_filter_set_hides_nothing :: proc(t: ^testing.T) {
	// An empty bit set would mean "nothing", so the unfiltered state has to be
	// the full set rather than the zero value.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "a.odin")
	command := add_entity(&builder, .Command, "odin test")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_message(&builder, .User_Message, "x")
	push_event(&builder, .File_Modify, primary = path, summary = "x")
	add_command_end(&builder, command, .Passed)
	add_test_result(&builder, test_case, .Passed)
	push_event(&builder, .Extension_Event, summary = "x")

	results := run_query(t, &builder, analysis.query_default())
	defer analysis.results_destroy(&results)

	testing.expect_value(t, len(results.matches), len(builder.trace.events))
	testing.expect_value(t, analysis.excluded_total(&results), 0)
}
