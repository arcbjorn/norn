package analysis

import "src:core"
import "src:replay"
import "src:trace/codec"
import "src:trace/model"

// Candidate-contributor scoring.
//
// docs/06-replay-and-analysis.md fixes the signal table reproduced below.
// Decision 008 fixes what the scores mean: Norn presents deterministic
// contributor candidates, not unsupported causal claims. Scores rank
// candidates; they are not probabilities, and the interface must say
// "candidate contributor" rather than "cause".
//
// Weights are fixed-point rather than floating point so that identical inputs
// produce byte-identical derived output, which docs/05 requires and which
// float summation order would quietly break.

// RULES_VERSION identifies this weight set. docs/06: rules and weights are
// versioned, and changing them invalidates the corresponding derived chunk,
// not the canonical trace.
RULES_VERSION :: 1

// Rule identifies one scoring signal. The name is part of the evidence a user
// sees, so it is stable and versioned alongside the weights.
Rule :: enum u8 {
	Diagnostic_Names_Path      = 0,
	Diagnostic_Line_In_Hunk    = 1,
	Test_File_Relationship     = 2,
	Same_Agent_Turn            = 3,
	File_Is_Command_Argument   = 4,
	Most_Recent_Edit_To_Path   = 5,
	Later_Repair_Same_Hunk     = 6,
}

// rule_id returns the versioned identifier shown with a score.
rule_id :: proc "contextless" (rule: Rule) -> string {
	switch rule {
	case .Diagnostic_Names_Path:    return "diagnostic_names_path@1"
	case .Diagnostic_Line_In_Hunk:  return "diagnostic_line_in_hunk@1"
	case .Test_File_Relationship:   return "test_file_relationship@1"
	case .Same_Agent_Turn:          return "same_agent_turn@1"
	case .File_Is_Command_Argument: return "file_is_command_argument@1"
	case .Most_Recent_Edit_To_Path: return "most_recent_edit_to_path@1"
	case .Later_Repair_Same_Hunk:   return "later_repair_same_hunk@1"
	}
	return "unknown"
}

// rule_reason returns the human-readable explanation, assembled from
// deterministic fields as docs/03 requires for inferred edges.
rule_reason :: proc "contextless" (rule: Rule) -> string {
	switch rule {
	case .Diagnostic_Names_Path:
		return "a diagnostic from this outcome names the edited path"
	case .Diagnostic_Line_In_Hunk:
		return "a diagnostic line falls inside a hunk this edit changed"
	case .Test_File_Relationship:
		return "the failing test has an explicit relationship to this file"
	case .Same_Agent_Turn:
		return "the edit and the triggering command share one agent turn"
	case .File_Is_Command_Argument:
		return "the edited file was passed as a direct command argument"
	case .Most_Recent_Edit_To_Path:
		return "this is the most recent edit to the candidate path"
	case .Later_Repair_Same_Hunk:
		return "a later successful repair modifies the same hunk"
	}
	return ""
}

Rule_Set :: bit_set[Rule; u8]

// Weights in the same fixed-point scale as model.Confidence, matching the
// docs/06 table exactly.
@(private)
rule_weight :: proc "contextless" (rule: Rule) -> int {
	switch rule {
	case .Diagnostic_Names_Path:    return 3500 // +0.35
	case .Diagnostic_Line_In_Hunk:  return 2500 // +0.25
	case .Test_File_Relationship:   return 2000 // +0.20
	case .Same_Agent_Turn:          return 1000 // +0.10
	case .File_Is_Command_Argument: return 1000 // +0.10
	case .Most_Recent_Edit_To_Path: return 1000 // +0.10
	case .Later_Repair_Same_Hunk:   return 1500 // +0.15
	}
	return 0
}

// GAP_CONFIDENCE_CAP is the ceiling applied when a replay gap affects the
// content a signal was computed from. docs/06: "replay gap affects relevant
// content — cap at 0.50".
//
// The cap encodes a real epistemic limit. A signal derived from content replay
// could not reconstruct is a signal derived from a guess, and it must not
// outrank a signal derived from verified bytes.
GAP_CONFIDENCE_CAP :: 5000

// Candidate is one ranked contributor hypothesis.
Candidate :: struct {
	mutation_event: model.Event_Id,
	path:           model.Entity_Id,
	sequence:       model.Sequence,
	score:          model.Confidence,
	rules:          Rule_Set,
	// True when a replay gap capped this score, so the interface can say the
	// confidence is limited by missing evidence rather than by weak signals.
	gap_capped: bool,
}

// Ranking is the ordered candidate list for one outcome.
Ranking :: struct {
	outcome:    model.Event_Id,
	window:     Window,
	candidates: [dynamic]Candidate,
	// Set when the window had no comparable passing outcome to anchor it,
	// which the interface reports as reduced certainty about scope.
	unanchored: bool,
}

ranking_destroy :: proc(ranking: ^Ranking) {
	delete(ranking.candidates)
	ranking^ = {}
}

// Scoring_Input bundles what scoring reads. Passing one struct keeps the
// signal procedures below honest about depending only on canonical facts.
Scoring_Input :: struct {
	trace:    ^codec.Trace,
	outcomes: ^Outcome_Index,
	engine:   ^replay.Engine,
}

// score_outcome ranks the mutations that may have contributed to an outcome.
//
// Every returned score carries the rule set that produced it, so the interface
// can expand a number into the deterministic contributions behind it. A score
// with no rules is not returned at all: a mutation that merely happened inside
// the window is temporal proximity, which decision 008 refuses to present as
// evidence.
score_outcome :: proc(
	input: Scoring_Input,
	target: Outcome,
	allocator := context.allocator,
) -> Ranking {
	ranking := Ranking {
		outcome    = target.event,
		candidates = make([dynamic]Candidate, 0, 8, allocator),
	}
	ranking.window = candidate_window(input.outcomes, input.trace, target)
	ranking.unanchored = !ranking.window.has_anchor

	// Collect the diagnostics this outcome reported, which several signals
	// depend on.
	diagnostics := collect_diagnostics(input.trace, target, context.temp_allocator)
	defer delete(diagnostics)

	// Paths named as direct arguments of the triggering command.
	argument_paths := collect_argument_paths(input.trace, target, context.temp_allocator)
	defer delete(argument_paths)

	// The most recent mutation per path inside the window, for the
	// most-recent-edit signal.
	latest := make(map[model.Entity_Id]model.Event_Id, 16, context.temp_allocator)
	defer delete(latest)
	for mutation in input.trace.mutations {
		sequence, ok := mutation_sequence(input.trace, mutation)
		if !ok || !window_contains(ranking.window, sequence) {
			continue
		}
		latest[mutation.path] = mutation.event_id
	}

	for mutation in input.trace.mutations {
		sequence, ok := mutation_sequence(input.trace, mutation)
		if !ok || !window_contains(ranking.window, sequence) {
			continue
		}

		candidate := Candidate {
			mutation_event = mutation.event_id,
			path           = mutation.path,
			sequence       = sequence,
		}

		total := 0

		// Diagnostic directly names edited path: +0.35.
		// Diagnostic line overlaps changed hunk: +0.25.
		for diagnostic in diagnostics {
			if diagnostic.path != mutation.path || diagnostic.path == model.NO_ENTITY {
				continue
			}
			if .Diagnostic_Names_Path not_in candidate.rules {
				candidate.rules += {.Diagnostic_Names_Path}
				total += rule_weight(.Diagnostic_Names_Path)
			}
			if .Diagnostic_Line_In_Hunk not_in candidate.rules &&
			   diagnostic_overlaps_mutation(input, mutation, diagnostic) {
				candidate.rules += {.Diagnostic_Line_In_Hunk}
				total += rule_weight(.Diagnostic_Line_In_Hunk)
			}
		}

		// Test-to-file relationship is explicit: +0.20.
		if target.kind == .Test && has_explicit_test_relationship(input.trace, target, mutation.path) {
			candidate.rules += {.Test_File_Relationship}
			total += rule_weight(.Test_File_Relationship)
		}

		// Mutation is in the same agent turn as the triggering command: +0.10.
		if target.span != model.NO_SPAN &&
		   mutation_span(input.trace, mutation) == target.span {
			candidate.rules += {.Same_Agent_Turn}
			total += rule_weight(.Same_Agent_Turn)
		}

		// File was passed as a direct command argument: +0.10.
		for path in argument_paths {
			if path == mutation.path {
				candidate.rules += {.File_Is_Command_Argument}
				total += rule_weight(.File_Is_Command_Argument)
				break
			}
		}

		// Mutation is the most recent edit to the candidate path: +0.10.
		if latest[mutation.path] == mutation.event_id {
			candidate.rules += {.Most_Recent_Edit_To_Path}
			total += rule_weight(.Most_Recent_Edit_To_Path)
		}

		// A later successful repair modifies the same hunk: +0.15.
		if has_later_repair(input, target, mutation) {
			candidate.rules += {.Later_Repair_Same_Hunk}
			total += rule_weight(.Later_Repair_Same_Hunk)
		}

		if candidate.rules == {} {
			// Only temporal proximity. Not evidence, so not a candidate.
			continue
		}

		// A replay gap affecting this mutation caps the score.
		if mutation_has_gap(input, mutation) {
			candidate.gap_capped = true
			if total > GAP_CONFIDENCE_CAP {
				total = GAP_CONFIDENCE_CAP
			}
		}

		// Clamp to [0, 1] in fixed point.
		if total > model.CONFIDENCE_SCALE {
			total = model.CONFIDENCE_SCALE
		}
		if total < 0 {
			total = 0
		}
		candidate.score = model.Confidence(total)

		append(&ranking.candidates, candidate)
	}

	sort_candidates(ranking.candidates[:])
	return ranking
}

// sort_candidates orders by descending score, then by descending sequence.
//
// The tiebreak is deterministic and meaningful: among equally scored edits the
// later one is closer to the failure. Insertion sort suits the small candidate
// lists a single outcome produces and keeps the order stable.
@(private)
sort_candidates :: proc(candidates: []Candidate) {
	for index in 1 ..< len(candidates) {
		current := candidates[index]
		position := index
		for position > 0 {
			previous := candidates[position - 1]
			higher :=
				previous.score > current.score ||
				(previous.score == current.score && previous.sequence >= current.sequence)
			if higher {
				break
			}
			candidates[position] = previous
			position -= 1
		}
		candidates[position] = current
	}
}

// mutation_sequence resolves the sequence of the event a mutation belongs to.
@(private)
mutation_sequence :: proc(
	trace: ^codec.Trace,
	mutation: model.Mutation,
) -> (
	sequence: model.Sequence,
	ok: bool,
) {
	index := int(mutation.event_id) - 1
	if index < 0 || index >= len(trace.events) {
		return 0, false
	}
	return trace.events[index].sequence, true
}

// mutation_span resolves the span containing a mutation's event.
@(private)
mutation_span :: proc(trace: ^codec.Trace, mutation: model.Mutation) -> model.Span_Id {
	index := int(mutation.event_id) - 1
	if index < 0 || index >= len(trace.events) {
		return model.NO_SPAN
	}
	return trace.events[index].parent_span_id
}

// collect_diagnostics gathers the diagnostics attributable to an outcome.
//
// A diagnostic is attributed when it is the outcome itself, or when it shares
// the outcome's span — which is the mechanical reconstruction docs/06 permits:
// events within one command span.
@(private)
collect_diagnostics :: proc(
	trace: ^codec.Trace,
	target: Outcome,
	allocator := context.allocator,
) -> [dynamic]model.Diagnostic_Payload {
	result := make([dynamic]model.Diagnostic_Payload, 0, 4, allocator)

	for event in trace.events {
		if event.kind != .Diagnostic {
			continue
		}
		attributable :=
			event.id == target.event ||
			(target.span != model.NO_SPAN && event.parent_span_id == target.span)
		if !attributable {
			continue
		}
		if payload, ok := model.get_diagnostic(&trace.payloads, event.payload); ok {
			append(&result, payload)
		}
	}

	// A test failure may itself name a location, which functions as a
	// diagnostic for scoring purposes.
	if payload, ok := model.get_test(&trace.payloads, target.payload); ok {
		if payload.path != model.NO_ENTITY {
			append(
				&result,
				model.Diagnostic_Payload {
					severity = .Error,
					path = payload.path,
					line = payload.line,
					message = payload.message,
				},
			)
		}
	}

	return result
}

// collect_argument_paths returns path entities passed directly to the command
// that produced an outcome.
//
// Only a real argument vector counts. docs/03 forbids parsing a shell string
// as if it were a trustworthy argv, so a command recorded only as text
// contributes no argument signal rather than a guessed one.
@(private)
collect_argument_paths :: proc(
	trace: ^codec.Trace,
	target: Outcome,
	allocator := context.allocator,
) -> [dynamic]model.Entity_Id {
	result := make([dynamic]model.Entity_Id, 0, 4, allocator)

	payload, ok := model.get_command(&trace.payloads, target.payload)
	if !ok || !payload.has_argv {
		return result
	}

	arguments := model.command_arguments(&trace.payloads, payload)
	for argument in arguments {
		// Match an argument against path entities by their interned name. The
		// comparison is on identifiers, not text: both sides were interned
		// from normalized paths, so equal identifiers mean the same path.
		for entity in trace.entities {
			if entity.kind == .Path && entity.name == argument {
				append(&result, entity.id)
			}
		}
	}
	return result
}

// has_explicit_test_relationship reports whether the trace records a `tests`
// edge between the outcome's test entity and a path.
//
// docs/06 weights this signal at +0.20 precisely because it is explicit: the
// relationship was recorded, not inferred from co-occurrence.
@(private)
has_explicit_test_relationship :: proc(
	trace: ^codec.Trace,
	target: Outcome,
	path: model.Entity_Id,
) -> bool {
	if target.test_case == model.NO_ENTITY || path == model.NO_ENTITY {
		return false
	}
	for edge in trace.edges {
		if edge.kind != .Tests || edge.origin != .Explicit {
			continue
		}
		from_test :=
			edge.from.kind == .Entity && model.Entity_Id(edge.from.id) == target.test_case
		to_path := edge.to.kind == .Entity && model.Entity_Id(edge.to.id) == path
		if from_test && to_path {
			return true
		}
	}
	return false
}

// diagnostic_overlaps_mutation reports whether a diagnostic's line falls inside
// a region this mutation changed.
//
// Without a patch there are no hunk boundaries to test, and claiming overlap
// from a whole-file rewrite would make the signal meaningless — every
// diagnostic in the file would "overlap". A full-content mutation therefore
// does not earn this signal, only the weaker names-the-path one.
@(private)
diagnostic_overlaps_mutation :: proc(
	input: Scoring_Input,
	mutation: model.Mutation,
	diagnostic: model.Diagnostic_Payload,
) -> bool {
	if diagnostic.line == 0 || mutation.patch_blob == model.NO_BLOB {
		return false
	}

	patch_bytes, ok := codec.trace_blob_content(input.trace, mutation.patch_blob)
	if !ok_content(patch_bytes, ok) {
		return false
	}

	patch, reason := replay.parse_patch(patch_bytes, context.temp_allocator)
	if reason != .None {
		return false
	}
	defer replay.patch_destroy(&patch)

	for hunk in patch.hunks {
		// The changed region in the resulting file, one-based and inclusive.
		start := u32(hunk.new_start)
		count := u32(hunk.new_count)
		if count == 0 {
			// A pure deletion still marks the join point as changed.
			if diagnostic_covers(diagnostic, start) {
				return true
			}
			continue
		}
		for line := start; line < start + count; line += 1 {
			if diagnostic_covers(diagnostic, line) {
				return true
			}
		}
	}
	return false
}

@(private)
diagnostic_covers :: proc "contextless" (
	diagnostic: model.Diagnostic_Payload,
	line: u32,
) -> bool {
	return model.diagnostic_covers_line(diagnostic, line)
}

// ok_content adapts the codec's error-returning fetch to a boolean test.
//
// Content that failed to fetch or verify is simply absent for scoring: a
// signal must never be awarded from bytes the reader refused to trust.
@(private)
ok_content :: proc(content: []byte, err: core.Error) -> bool {
	return core.ok(err) && content != nil
}

// has_later_repair reports whether a mutation after the outcome touches the
// same path and precedes a passing comparable outcome.
//
// docs/06 phrases this as "a later successful repair modifies same hunk". Hunk
// identity requires both edits to be patches; when they are not, sharing the
// path plus leading to a pass is the strongest statement the evidence supports,
// and the signal is not awarded.
@(private)
has_later_repair :: proc(
	input: Scoring_Input,
	target: Outcome,
	mutation: model.Mutation,
) -> bool {
	// Find a later passing outcome comparable to the failure.
	repair_bound := model.Sequence(0)
	for candidate in input.outcomes.outcomes {
		if candidate.sequence <= target.sequence {
			continue
		}
		if candidate.status == .Passed && comparable(candidate, target) {
			repair_bound = candidate.sequence
			break
		}
	}
	if repair_bound == 0 {
		return false
	}

	for later in input.trace.mutations {
		if later.event_id == mutation.event_id || later.path != mutation.path {
			continue
		}
		sequence, ok := mutation_sequence(input.trace, later)
		if !ok || sequence <= target.sequence || sequence > repair_bound {
			continue
		}
		if hunks_overlap(input, mutation, later) {
			return true
		}
	}
	return false
}

// hunks_overlap reports whether two patch mutations touch overlapping regions.
@(private)
hunks_overlap :: proc(
	input: Scoring_Input,
	first: model.Mutation,
	second: model.Mutation,
) -> bool {
	if first.patch_blob == model.NO_BLOB || second.patch_blob == model.NO_BLOB {
		return false
	}

	first_bytes, first_ok := codec.trace_blob_content(input.trace, first.patch_blob)
	second_bytes, second_ok := codec.trace_blob_content(input.trace, second.patch_blob)
	if !ok_content(first_bytes, first_ok) || !ok_content(second_bytes, second_ok) {
		return false
	}

	a, a_reason := replay.parse_patch(first_bytes, context.temp_allocator)
	if a_reason != .None {
		return false
	}
	defer replay.patch_destroy(&a)

	b, b_reason := replay.parse_patch(second_bytes, context.temp_allocator)
	if b_reason != .None {
		return false
	}
	defer replay.patch_destroy(&b)

	for first_hunk in a.hunks {
		first_start := first_hunk.new_start
		first_end := first_start + max(first_hunk.new_count, 1) - 1
		for second_hunk in b.hunks {
			second_start := second_hunk.old_start
			second_end := second_start + max(second_hunk.old_count, 1) - 1
			if first_start <= second_end && second_start <= first_end {
				return true
			}
		}
	}
	return false
}

// mutation_has_gap reports whether replay could not reconstruct this mutation.
@(private)
mutation_has_gap :: proc(input: Scoring_Input, mutation: model.Mutation) -> bool {
	// The recorded status is the importer's verdict; the engine's outcome is
	// what replay actually produced. Either indicating a gap caps the score.
	if model.is_replay_gap(mutation.status) {
		return true
	}
	if input.engine == nil {
		return false
	}
	for outcome in input.engine.outcomes {
		if outcome.event == mutation.event_id {
			return model.is_replay_gap(outcome.status)
		}
	}
	return false
}
