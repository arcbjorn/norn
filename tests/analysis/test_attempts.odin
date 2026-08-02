package test_analysis

import "core:testing"

import "src:analysis"
import "src:trace/model"

// Attempt and retry-loop detection, plus the evidence stack.

@(test)
a_new_goal_starts_a_new_attempt :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_message(&builder, .User_Message, "first goal", true)
	add_mutation(&builder, path)
	add_test_result(&builder, test_case, .Failed)
	add_message(&builder, .User_Message, "second goal", true)
	add_mutation(&builder, path)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	attempts := analysis.detect_attempts(&builder.trace, &index)
	defer analysis.attempt_index_destroy(&attempts)

	testing.expect_value(t, len(attempts.attempts), 2)
	testing.expect_value(t, attempts.attempts[0].end_reason, analysis.Attempt_End.New_Goal)
	testing.expect_value(t, attempts.attempts[1].end_reason, analysis.Attempt_End.Session_End)
}

@(test)
a_comparable_pass_closes_an_attempt :: proc(t: ^testing.T) {
	// docs/06: an attempt ends at a successful comparable outcome. Only a pass
	// comparable to a failure the attempt contained counts.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_message(&builder, .User_Message, "fix the test", true)
	add_mutation(&builder, path)
	add_test_result(&builder, test_case, .Failed)
	add_mutation(&builder, path)
	add_test_result(&builder, test_case, .Passed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	attempts := analysis.detect_attempts(&builder.trace, &index)
	defer analysis.attempt_index_destroy(&attempts)

	testing.expect_value(t, len(attempts.attempts), 1)
	testing.expect_value(
		t,
		attempts.attempts[0].end_reason,
		analysis.Attempt_End.Comparable_Pass,
	)
	testing.expect(t, attempts.attempts[0].succeeded)
	testing.expect_value(t, attempts.attempts[0].mutation_count, 2)
	testing.expect_value(t, attempts.attempts[0].failure_count, 1)
}

@(test)
an_unrelated_pass_does_not_close_an_attempt :: proc(t: ^testing.T) {
	// A passing test unrelated to the failing work says nothing about whether
	// that work succeeded.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	failing := add_entity(&builder, .Test_Case, "failing")
	unrelated := add_entity(&builder, .Test_Case, "unrelated")

	add_message(&builder, .User_Message, "fix it", true)
	add_mutation(&builder, path)
	add_test_result(&builder, failing, .Failed)
	add_test_result(&builder, unrelated, .Passed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	attempts := analysis.detect_attempts(&builder.trace, &index)
	defer analysis.attempt_index_destroy(&attempts)

	testing.expect_value(t, len(attempts.attempts), 1)
	testing.expect(t, !attempts.attempts[0].succeeded)
	testing.expect_value(t, attempts.attempts[0].end_reason, analysis.Attempt_End.Session_End)
}

@(test)
a_long_idle_gap_ends_an_attempt :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_message(&builder, .User_Message, "start", true)
	add_mutation(&builder, path)

	// A pause longer than the boundary separates the work that follows.
	advance_clock(&builder, analysis.INACTIVITY_BOUNDARY_NS * 2)
	add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	attempts := analysis.detect_attempts(&builder.trace, &index)
	defer analysis.attempt_index_destroy(&attempts)

	testing.expect(t, len(attempts.attempts) >= 1)
	testing.expect_value(t, attempts.attempts[0].end_reason, analysis.Attempt_End.Inactivity)
}

@(test)
attempt_detection_does_not_modify_the_trace :: proc(t: ^testing.T) {
	// docs/06: attempt detection is navigation metadata and does not rewrite
	// original spans.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")
	span := add_span(&builder, .Agent_Turn)

	start := add_message(&builder, .User_Message, "go", true)
	add_mutation(&builder, path, span)
	add_test_result(&builder, test_case, .Failed, span)
	close_span(&builder, span, start)

	spans_before := len(builder.trace.spans)
	events_before := len(builder.trace.events)
	first_span := builder.trace.spans[0]

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	attempts := analysis.detect_attempts(&builder.trace, &index)
	defer analysis.attempt_index_destroy(&attempts)

	testing.expect_value(t, len(builder.trace.spans), spans_before)
	testing.expect_value(t, len(builder.trace.events), events_before)
	testing.expect_value(t, builder.trace.spans[0].id, first_span.id)
	testing.expect_value(t, builder.trace.spans[0].kind, first_span.kind)
	testing.expect_value(t, builder.trace.spans[0].start_sequence, first_span.start_sequence)
}

@(test)
repeated_identical_errors_form_a_retry_loop :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	tool := add_entity(&builder, .Actor_Tool, "edit_file")

	add_tool_error(&builder, tool, "file not found")
	add_tool_error(&builder, tool, "file not found")
	add_tool_error(&builder, tool, "file not found")

	loops := analysis.detect_retry_loops(&builder.trace)
	defer analysis.retry_index_destroy(&loops)

	testing.expect_value(t, len(loops.loops), 1)
	testing.expect_value(t, loops.loops[0].repeats, 3)
}

@(test)
two_repeats_are_not_yet_a_loop :: proc(t: ^testing.T) {
	// A single repeat is ordinary correction. Flagging it would make the
	// signal noise.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	tool := add_entity(&builder, .Actor_Tool, "edit_file")
	add_tool_error(&builder, tool, "permission denied")
	add_tool_error(&builder, tool, "permission denied")

	loops := analysis.detect_retry_loops(&builder.trace)
	defer analysis.retry_index_destroy(&loops)

	testing.expect_value(t, len(loops.loops), 0)
}

@(test)
distinct_errors_do_not_form_a_loop :: proc(t: ^testing.T) {
	// Identity is the interned message, not a similarity measure. Three
	// different failures are progress, not a loop.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	tool := add_entity(&builder, .Actor_Tool, "edit_file")
	add_tool_error(&builder, tool, "first problem")
	add_tool_error(&builder, tool, "second problem")
	add_tool_error(&builder, tool, "third problem")

	loops := analysis.detect_retry_loops(&builder.trace)
	defer analysis.retry_index_destroy(&loops)

	testing.expect_value(t, len(loops.loops), 0)
}

@(test)
evidence_stack_orders_levels_as_documented :: proc(t: ^testing.T) {
	// docs/01 fixes the order: the outcome, attached parents, mutations in the
	// window, associated reads, then inferred candidates.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_tests_edge(&builder, test_case, path)
	add_mutation(&builder, path)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	input := analysis.Scoring_Input{trace = &builder.trace, outcomes = &index}
	ranking := analysis.score_outcome(input, target)
	defer analysis.ranking_destroy(&ranking)

	stack := analysis.build_evidence_stack(input, target, &ranking)
	defer analysis.evidence_stack_destroy(&stack)

	testing.expect(t, len(stack.entries) >= 2)

	// The outcome itself comes first and is explicit.
	testing.expect_value(t, stack.entries[0].event, failure)
	testing.expect_value(t, stack.entries[0].level, analysis.Evidence_Level.Explicit)

	// Inferred entries come last: no explicit or reconstructed entry may
	// follow an inferred one, or the interface would present a guess above a
	// recorded fact.
	seen_inferred := false
	for entry in stack.entries {
		if entry.level == .Inferred {
			seen_inferred = true
			continue
		}
		testing.expect(
			t,
			!seen_inferred,
			"a non-inferred entry must not follow an inferred one",
		)
	}
	testing.expect(t, seen_inferred, "the stack must include the candidate")
}

@(test)
evidence_stack_reports_uncertainty :: proc(t: ^testing.T) {
	// docs/01 requires the stack to surface uncertainty and missing evidence
	// rather than omitting them.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	test_case := add_entity(&builder, .Test_Case, "t")
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	input := analysis.Scoring_Input{trace = &builder.trace, outcomes = &index}
	ranking := analysis.score_outcome(input, target)
	defer analysis.ranking_destroy(&ranking)

	stack := analysis.build_evidence_stack(input, target, &ranking)
	defer analysis.evidence_stack_destroy(&stack)

	// No comparable pass and no candidates: both must be stated.
	testing.expect(t, len(stack.uncertainties) >= 2)
}

@(test)
candidate_edges_carry_rule_and_reason :: proc(t: ^testing.T) {
	// docs/03: an inferred edge carries confidence, a rule identifier, and a
	// human-readable reason.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	test_case := add_entity(&builder, .Test_Case, "t")

	add_tests_edge(&builder, test_case, path)
	add_mutation(&builder, path)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	input := analysis.Scoring_Input{trace = &builder.trace, outcomes = &index}
	ranking := analysis.score_outcome(input, target)
	defer analysis.ranking_destroy(&ranking)

	edges := analysis.candidate_edges(&ranking, &builder.trace.strings)
	defer delete(edges)

	testing.expect(t, len(edges) > 0)
	for edge in edges {
		testing.expect_value(t, edge.kind, model.Edge_Kind.Candidate_Contributor)
		testing.expect_value(t, edge.origin, model.Edge_Origin.Inferred)
		testing.expect(t, edge.rule != model.EMPTY_STRING, "an inferred edge must name its rule")
		testing.expect(t, edge.reason != model.EMPTY_STRING, "an inferred edge must give a reason")

		rule_text, _ := model.string_get(&builder.trace.strings, edge.rule)
		testing.expect(t, rule_text != "", "the rule identifier must resolve")
	}
}

@(test)
derived_edges_record_their_origin :: proc(t: ^testing.T) {
	// docs/06 requires the UI to identify the evidence level of every
	// relationship, which depends on the origin being set here.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/a.odin")
	add_mutation(&builder, path)
	add_diagnostic(&builder, path, 4, "problem")

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	edges := analysis.build_evidence_edges(&builder.trace, &index)
	defer delete(edges)

	testing.expect(t, len(edges) > 0)

	saw_writes := false
	saw_diagnoses := false
	for edge in edges {
		testing.expect(
			t,
			edge.origin == .Explicit || edge.origin == .Reconstructed,
			"derived structural edges are never inferred",
		)
		if edge.kind == .Writes {
			saw_writes = true
		}
		if edge.kind == .Diagnoses {
			saw_diagnoses = true
		}
	}
	testing.expect(t, saw_writes, "a mutation must produce a writes edge")
	testing.expect(t, saw_diagnoses, "a located diagnostic must produce a diagnoses edge")
}
