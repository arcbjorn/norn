package test_analysis

import "core:testing"

import "src:analysis"
import "src:trace/model"

// Comparability and windows.
//
// docs/06: two test outcomes are comparable when they have the same stable
// test identity, or when the same normalized command and working directory
// produced structured results for the same suite. Similar text alone is
// insufficient. Most of these tests assert the *rejections*, because a wrong
// "comparable" verdict silently excludes candidate mutations.

@(test)
same_test_identity_is_comparable :: proc(t: ^testing.T) {
	a := analysis.Outcome{kind = .Test, test_case = 1, status = .Passed}
	b := analysis.Outcome{kind = .Test, test_case = 1, status = .Failed}
	testing.expect(t, analysis.comparable(a, b))
}

@(test)
different_test_identity_is_not_comparable :: proc(t: ^testing.T) {
	a := analysis.Outcome{kind = .Test, test_case = 1}
	b := analysis.Outcome{kind = .Test, test_case = 2}
	testing.expect(t, !analysis.comparable(a, b))
}

@(test)
a_test_without_identity_is_not_comparable :: proc(t: ^testing.T) {
	// Absent identity means unknown, and unknown must never be treated as a
	// match: it would anchor the window on an unrelated result.
	a := analysis.Outcome{kind = .Test, test_case = model.NO_ENTITY}
	b := analysis.Outcome{kind = .Test, test_case = model.NO_ENTITY}
	testing.expect(t, !analysis.comparable(a, b))
}

@(test)
build_and_lint_are_not_comparable_to_each_other :: proc(t: ^testing.T) {
	// docs/06: build and lint use separate comparability rules, and a
	// successful formatter run is not a passing build.
	build := analysis.Outcome{kind = .Build, command = 1, structured = true}
	lint := analysis.Outcome{kind = .Lint, command = 1, structured = true}
	testing.expect(t, !analysis.comparable(build, lint))
}

@(test)
builds_need_structure_to_be_comparable :: proc(t: ^testing.T) {
	// Without structured results there is only output that happens to look
	// similar, which docs/06 rules out explicitly.
	structured := analysis.Outcome{kind = .Build, command = 1, structured = true}
	unstructured := analysis.Outcome{kind = .Build, command = 1, structured = false}

	testing.expect(t, analysis.comparable(structured, structured))
	testing.expect(t, !analysis.comparable(structured, unstructured))
	testing.expect(t, !analysis.comparable(unstructured, unstructured))
}

@(test)
builds_in_different_directories_are_not_comparable :: proc(t: ^testing.T) {
	a := analysis.Outcome{kind = .Build, command = 1, working_directory = 1, structured = true}
	b := analysis.Outcome{kind = .Build, command = 1, working_directory = 2, structured = true}
	testing.expect(t, !analysis.comparable(a, b))
}

@(test)
plain_commands_are_never_comparable :: proc(t: ^testing.T) {
	// Version one has no comparability rule for arbitrary commands. Treating
	// two runs of one command as comparable would be exactly the "similar
	// text" mistake docs/06 forbids.
	a := analysis.Outcome{kind = .Command, command = 1, status = .Passed}
	b := analysis.Outcome{kind = .Command, command = 1, status = .Failed}
	testing.expect(t, !analysis.comparable(a, b))
}

@(test)
window_is_anchored_by_the_last_comparable_pass :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")
	other := add_entity(&builder, .Test_Case, "other")

	add_mutation(&builder, path)
	// A pass of a *different* test must not anchor the window.
	add_test_result(&builder, other, .Passed)
	anchor := add_test_result(&builder, test_case, .Passed)
	add_mutation(&builder, path)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	window := analysis.candidate_window(&index, &builder.trace, target)
	testing.expect(t, window.has_anchor)
	testing.expect_value(t, window.anchor, anchor)
}

@(test)
window_without_a_comparable_pass_falls_back_to_the_phase :: proc(t: ^testing.T) {
	// docs/06: if no comparable pass exists, the window begins at the
	// containing phase or session start. Absence of a prior pass widens the
	// window rather than emptying it.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_mutation(&builder, path)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	window := analysis.candidate_window(&index, &builder.trace, target)
	testing.expect(t, !window.has_anchor)
	testing.expect_value(t, window.from, model.Sequence(0))
	testing.expect(t, analysis.window_contains(window, model.Sequence(1)))
}

@(test)
outcome_index_classifies_every_outcome_kind :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")
	command := add_entity(&builder, .Command, "build")

	add_test_result(&builder, test_case, .Failed)
	add_command_end(&builder, command, .Failed)
	add_diagnostic(&builder, path, 1, "broken")

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	testing.expect_value(t, len(index.outcomes), 3)
	testing.expect_value(t, index.outcomes[0].kind, analysis.Outcome_Kind.Test)
	testing.expect_value(t, index.outcomes[1].kind, analysis.Outcome_Kind.Command)
	testing.expect_value(t, index.outcomes[2].kind, analysis.Outcome_Kind.Diagnostic)

	// An error-level diagnostic reads as a failure to investigate.
	testing.expect(t, analysis.outcome_is_failure(index.outcomes[2]))
}
