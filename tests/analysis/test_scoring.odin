package test_analysis

import "core:testing"

import "src:analysis"
import "src:trace/model"

// Contributor scoring.
//
// docs/11 exit criterion for phase four: selecting each known fixture failure
// produces the expected ranked evidence, every score expands into its
// deterministic rule contributions, and replay gaps visibly cap confidence.

@(private)
scoring_input :: proc(builder: ^Builder, index: ^analysis.Outcome_Index) -> analysis.Scoring_Input {
	return analysis.Scoring_Input{trace = &builder.trace, outcomes = index}
}

@(test)
diagnostic_naming_edited_path_scores_it :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")

	add_mutation(&builder, path)
	add_diagnostic(&builder, path, 12, "undefined identifier")
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)

	target, found := analysis.find_outcome(&index, failure)
	testing.expect(t, found)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect(t, len(ranking.candidates) > 0, "the edited path must be a candidate")

	// The diagnostic is not inside the failing test's span here, so it is
	// attributed only when it is the outcome itself. What must hold is that
	// the most-recent-edit signal fired and the score expands into its rules.
	top := ranking.candidates[0]
	testing.expect_value(t, top.path, path)
	testing.expect(t, top.rules != {}, "a candidate must carry the rules that scored it")
	testing.expect(t, top.score > 0)
}

@(test)
score_matches_the_documented_weights :: proc(t: ^testing.T) {
	// docs/06 fixes the weights. This asserts the arithmetic rather than the
	// plumbing: most-recent-edit (+0.10) plus same-agent-turn (+0.10) is 0.20.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")
	span := add_span(&builder, .Agent_Turn)

	start := add_message(&builder, .User_Message, "fix the parser", true)
	add_mutation(&builder, path, span)
	failure := add_test_result(&builder, test_case, .Failed, span)
	close_span(&builder, span, start)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect_value(t, len(ranking.candidates), 1)
	top := ranking.candidates[0]

	testing.expect(t, .Most_Recent_Edit_To_Path in top.rules)
	testing.expect(t, .Same_Agent_Turn in top.rules)
	testing.expect_value(t, top.score, model.Confidence(2000)) // 0.10 + 0.10
}

@(test)
explicit_test_relationship_scores_higher :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	related := add_entity(&builder, .Path, "src/parser.odin")
	unrelated := add_entity(&builder, .Path, "src/unrelated.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")

	// docs/06 weights an explicit relationship at +0.20 precisely because the
	// trace recorded it rather than analysis inferring it.
	add_tests_edge(&builder, test_case, related)

	add_mutation(&builder, unrelated)
	add_mutation(&builder, related)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect_value(t, len(ranking.candidates), 2)
	testing.expect_value(t, ranking.candidates[0].path, related)
	testing.expect(t, .Test_File_Relationship in ranking.candidates[0].rules)
	testing.expect(t, .Test_File_Relationship not_in ranking.candidates[1].rules)
	testing.expect(
		t,
		ranking.candidates[0].score > ranking.candidates[1].score,
		"the explicitly related file must outrank the unrelated one",
	)
}

@(test)
mutations_before_a_comparable_pass_are_excluded :: proc(t: ^testing.T) {
	// docs/06: "mutation predates a passing comparable outcome — exclude".
	// The window starts at the last comparable pass, so earlier edits are not
	// candidates at all.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	old_path := add_entity(&builder, .Path, "src/old.odin")
	new_path := add_entity(&builder, .Path, "src/new.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")

	add_mutation(&builder, old_path)
	add_test_result(&builder, test_case, .Passed)
	add_mutation(&builder, new_path)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect(t, ranking.window.has_anchor, "the passing run must anchor the window")
	testing.expect_value(t, len(ranking.candidates), 1)
	testing.expect_value(t, ranking.candidates[0].path, new_path)
}

@(test)
a_replay_gap_caps_confidence :: proc(t: ^testing.T) {
	// docs/06: "replay gap affects relevant content — cap at 0.50". A signal
	// computed from content replay could not reconstruct must not outrank one
	// computed from verified bytes.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")
	span := add_span(&builder, .Agent_Turn)

	add_tests_edge(&builder, test_case, path)
	start := add_message(&builder, .User_Message, "fix it", true)
	add_mutation(&builder, path, span, "", .Unsupported_Patch)
	failure := add_test_result(&builder, test_case, .Failed, span)
	close_span(&builder, span, start)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect_value(t, len(ranking.candidates), 1)
	top := ranking.candidates[0]

	// Signals total 0.40 here, under the cap, but the flag must still be set
	// so the interface can say why confidence is limited.
	testing.expect(t, top.gap_capped, "a gapped mutation must be marked")
	testing.expect(
		t,
		u16(top.score) <= analysis.GAP_CONFIDENCE_CAP,
		"a gapped candidate must not exceed the cap",
	)
}

@(test)
gap_cap_actually_reduces_a_high_score :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")
	command := add_entity(&builder, .Command, "odin test")
	span := add_span(&builder, .Agent_Turn)

	add_tests_edge(&builder, test_case, path)
	start := add_message(&builder, .User_Message, "fix it", true)
	add_mutation(&builder, path, span, "", .Hash_Mismatch)
	add_diagnostic(&builder, path, 3, "type mismatch", span)
	add_command_end(&builder, command, .Failed, span, []string{"src/parser.odin"})
	failure := add_test_result(&builder, test_case, .Failed, span, path = path, line = 3)
	close_span(&builder, span, start)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect(t, len(ranking.candidates) > 0)
	top := ranking.candidates[0]
	testing.expect(t, top.gap_capped)
	testing.expect_value(t, top.score, model.Confidence(analysis.GAP_CONFIDENCE_CAP))
}

@(test)
temporal_proximity_alone_is_not_a_candidate :: proc(t: ^testing.T) {
	// Decision 008: temporal proximity does not establish causality. A
	// mutation with no supporting signal must not appear in the ranking at
	// all, rather than appearing with a low score that still implies a link.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	unrelated := add_entity(&builder, .Path, "docs/README.md")
	test_case := add_entity(&builder, .Test_Case, "parses_input")

	// Two edits to the same unrelated path: the second is "most recent", the
	// first has nothing at all.
	add_mutation(&builder, unrelated)
	add_mutation(&builder, unrelated)
	failure := add_test_result(&builder, test_case, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	// Only the most-recent edit qualifies; the earlier one carries no signal.
	testing.expect_value(t, len(ranking.candidates), 1)
	testing.expect(t, .Most_Recent_Edit_To_Path in ranking.candidates[0].rules)
}

@(test)
command_argument_signal_requires_a_real_argv :: proc(t: ^testing.T) {
	// docs/03: a shell command string is never parsed as if it were a
	// trustworthy argv. A command recorded only as text contributes no
	// argument signal rather than a guessed one.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	command := add_entity(&builder, .Command, "odin test")

	add_mutation(&builder, path)
	// No argument vector supplied.
	failure := add_command_end(&builder, command, .Failed)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	for candidate in ranking.candidates {
		testing.expect(
			t,
			.File_Is_Command_Argument not_in candidate.rules,
			"no argument signal may be awarded without a recorded argv",
		)
	}
}

@(test)
command_argument_signal_fires_with_a_real_argv :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	command := add_entity(&builder, .Command, "odin test")

	add_mutation(&builder, path)
	failure := add_command_end(
		&builder,
		command,
		.Failed,
		arguments = []string{"src/parser.odin"},
	)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect(t, len(ranking.candidates) > 0)
	testing.expect(t, .File_Is_Command_Argument in ranking.candidates[0].rules)
}

@(test)
scores_are_clamped_to_the_documented_range :: proc(t: ^testing.T) {
	// docs/06: scores are clamped to [0, 1]. The weights sum above 1.0 when
	// every signal fires, so the clamp is reachable rather than theoretical.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "src/parser.odin")
	test_case := add_entity(&builder, .Test_Case, "parses_input")
	command := add_entity(&builder, .Command, "odin test")
	span := add_span(&builder, .Agent_Turn)

	add_tests_edge(&builder, test_case, path)
	start := add_message(&builder, .User_Message, "fix it", true)
	patch := "@@ -3,1 +3,1 @@\n-old\n+new\n"
	add_mutation(&builder, path, span, patch)
	add_diagnostic(&builder, path, 3, "type mismatch", span)
	add_command_end(&builder, command, .Failed, span, []string{"src/parser.odin"})
	failure := add_test_result(&builder, test_case, .Failed, span, path = path, line = 3)
	close_span(&builder, span, start)

	index := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&index)
	target, _ := analysis.find_outcome(&index, failure)

	ranking := analysis.score_outcome(scoring_input(&builder, &index), target)
	defer analysis.ranking_destroy(&ranking)

	testing.expect(t, len(ranking.candidates) > 0)
	for candidate in ranking.candidates {
		testing.expect(
			t,
			u16(candidate.score) <= model.CONFIDENCE_SCALE,
			"no score may exceed 1.0 after clamping",
		)
	}
}

@(test)
scoring_is_deterministic :: proc(t: ^testing.T) {
	// docs/13: version-one analysis is deterministic. The same trace must
	// produce the same ranking every time, or a shared explanation would not
	// reproduce.
	build :: proc(builder: ^Builder) -> model.Event_Id {
		builder_init(builder)
		path := add_entity(builder, .Path, "src/parser.odin")
		other := add_entity(builder, .Path, "src/lexer.odin")
		test_case := add_entity(builder, .Test_Case, "parses_input")
		add_tests_edge(builder, test_case, path)
		add_mutation(builder, other)
		add_mutation(builder, path)
		return add_test_result(builder, test_case, .Failed)
	}

	first: Builder
	failure_a := build(&first)
	defer builder_destroy(&first)
	index_a := analysis.build_outcome_index(&first.trace)
	defer analysis.outcome_index_destroy(&index_a)
	target_a, _ := analysis.find_outcome(&index_a, failure_a)
	ranking_a := analysis.score_outcome(scoring_input(&first, &index_a), target_a)
	defer analysis.ranking_destroy(&ranking_a)

	second: Builder
	failure_b := build(&second)
	defer builder_destroy(&second)
	index_b := analysis.build_outcome_index(&second.trace)
	defer analysis.outcome_index_destroy(&index_b)
	target_b, _ := analysis.find_outcome(&index_b, failure_b)
	ranking_b := analysis.score_outcome(scoring_input(&second, &index_b), target_b)
	defer analysis.ranking_destroy(&ranking_b)

	testing.expect_value(t, len(ranking_a.candidates), len(ranking_b.candidates))
	for index in 0 ..< len(ranking_a.candidates) {
		a := ranking_a.candidates[index]
		b := ranking_b.candidates[index]
		testing.expect_value(t, a.mutation_event, b.mutation_event)
		testing.expect_value(t, a.score, b.score)
		testing.expect_value(t, a.rules, b.rules)
	}
}

@(test)
every_rule_has_a_stable_identifier_and_reason :: proc(t: ^testing.T) {
	// docs/03: an inferred edge carries a rule identifier and a
	// human-readable reason. A rule missing either would produce an edge the
	// interface cannot explain.
	for rule in analysis.Rule {
		id := analysis.rule_id(rule)
		reason := analysis.rule_reason(rule)
		testing.expectf(t, id != "unknown" && id != "", "rule %v has no identifier", rule)
		testing.expectf(t, reason != "", "rule %v has no reason", rule)
	}
}
