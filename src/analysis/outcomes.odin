package analysis

import "src:trace/codec"
import "src:trace/model"

// Outcomes and comparability.
//
// docs/06-replay-and-analysis.md: two test outcomes are comparable when they
// have the same stable test identity, or when the same normalized command and
// working directory produced structured results for the same suite. Similar
// text alone is insufficient.
//
// That last sentence is the load-bearing one. Comparing outcomes by message
// text would let an unrelated failure look like a regression of a passing
// test, and the whole contributor ranking is built on top of the window
// between two comparable outcomes.

// Outcome_Kind separates the comparability families. docs/06: build and lint
// commands use separate comparability rules, and a successful formatter run is
// not a passing build.
Outcome_Kind :: enum u8 {
	Unknown = 0,
	Test    = 1,
	Build   = 2,
	Lint    = 3,
	Command = 4,
	Diagnostic = 5,
	Explicit_Error = 6,
}

outcome_kind_name :: proc "contextless" (kind: Outcome_Kind) -> string {
	switch kind {
	case .Unknown:        return "unknown"
	case .Test:           return "test"
	case .Build:          return "build"
	case .Lint:           return "lint"
	case .Command:        return "command"
	case .Diagnostic:     return "diagnostic"
	case .Explicit_Error: return "explicit_error"
	}
	return "unknown"
}

// Outcome is a selectable result, indexed for analysis.
//
// docs/01: commands, test runs, diagnostics, and explicit errors are outcomes,
// and selecting one opens an evidence stack.
Outcome :: struct {
	event:    model.Event_Id,
	sequence: model.Sequence,
	kind:     Outcome_Kind,
	status:   model.Outcome_Status,
	span:     model.Span_Id,

	// Identity for comparability. A test outcome uses its test-case entity; a
	// build or lint outcome uses its command entity plus working directory.
	test_case:         model.Entity_Id,
	suite:             model.Entity_Id,
	command:           model.Entity_Id,
	working_directory: model.Entity_Id,

	// True when the result came from a structured report rather than from
	// parsing free text. docs/06 requires structured results for
	// command-based comparability.
	structured: bool,

	// Payload reference, so the evidence stack can show the detail without
	// copying it here.
	payload: model.Payload_Ref,
}

// is_failure reports whether this outcome is one a user would investigate.
outcome_is_failure :: proc "contextless" (outcome: Outcome) -> bool {
	return model.is_failure(outcome.status)
}

// comparable reports whether two outcomes measure the same thing.
//
// Comparability is deliberately narrow. When it is uncertain the answer is
// false, which widens the candidate window rather than silently excluding
// mutations that a wrong "comparable" verdict would have ruled out.
comparable :: proc "contextless" (a: Outcome, b: Outcome) -> bool {
	if a.kind != b.kind {
		return false
	}

	#partial switch a.kind {
	case .Test:
		// Same stable test identity. The entity is established at import, so
		// this is identity comparison rather than text matching.
		if a.test_case == model.NO_ENTITY || b.test_case == model.NO_ENTITY {
			return false
		}
		return a.test_case == b.test_case

	case .Build, .Lint:
		// Same normalized command and working directory, and both structured.
		// Without structure there is no reliable statement of what was built,
		// only output that happens to look similar.
		if !a.structured || !b.structured {
			return false
		}
		if a.command == model.NO_ENTITY || b.command == model.NO_ENTITY {
			return false
		}
		if a.command != b.command || a.working_directory != b.working_directory {
			return false
		}
		// When both name a suite, they must name the same one.
		return a.suite == b.suite
	}

	// Plain commands, diagnostics, and explicit errors have no comparability
	// rule in version one. Treating two arbitrary command runs as comparable
	// would be the "similar text alone" mistake docs/06 forbids.
	return false
}

// Outcome_Index holds the outcomes of a trace in sequence order.
Outcome_Index :: struct {
	outcomes: [dynamic]Outcome,
}

outcome_index_destroy :: proc(index: ^Outcome_Index) {
	delete(index.outcomes)
	index^ = {}
}

// build_outcome_index extracts every outcome from a trace.
//
// Events arrive in sequence order, so the resulting slice is ordered without
// sorting, which matters because every window computation below is a scan
// backwards from a selected outcome.
build_outcome_index :: proc(
	trace: ^codec.Trace,
	allocator := context.allocator,
) -> Outcome_Index {
	index: Outcome_Index
	index.outcomes = make([dynamic]Outcome, 0, 32, allocator)

	for event in trace.events {
		if !model.is_outcome(event.kind) {
			continue
		}

		outcome := Outcome {
			event    = event.id,
			sequence = event.sequence,
			span     = event.parent_span_id,
			payload  = event.payload,
		}

		#partial switch event.kind {
		case .Test_Case_Result, .Test_Run_End:
			outcome.kind = .Test
			if payload, ok := model.get_test(&trace.payloads, event.payload); ok {
				outcome.test_case = payload.test_case
				outcome.suite = payload.suite
				outcome.command = payload.command
				outcome.status = payload.status
				// A test payload exists only when the runner reported a
				// structured result.
				outcome.structured = true
			} else {
				outcome.test_case = event.primary_entity_id
			}

		case .Build_Result, .Lint_Result:
			outcome.kind = .Build if event.kind == .Build_Result else .Lint
			if payload, ok := model.get_command(&trace.payloads, event.payload); ok {
				outcome.command = payload.command
				outcome.working_directory = payload.working_directory
				outcome.status = payload.status
				outcome.structured = true
			}

		case .Command_End:
			outcome.kind = .Command
			if payload, ok := model.get_command(&trace.payloads, event.payload); ok {
				outcome.command = payload.command
				outcome.working_directory = payload.working_directory
				outcome.status = payload.status
			}

		case .Diagnostic:
			outcome.kind = .Diagnostic
			if payload, ok := model.get_diagnostic(&trace.payloads, event.payload); ok {
				// A diagnostic's severity stands in for a status: an error-level
				// diagnostic is a failure to investigate.
				outcome.status =
					.Failed if payload.severity >= .Error else .Unknown
			}

		case .Explicit_Error:
			outcome.kind = .Explicit_Error
			outcome.status = .Errored
		}

		append(&index.outcomes, outcome)
	}

	return index
}

// find_outcome returns the outcome for an event identifier.
find_outcome :: proc(
	index: ^Outcome_Index,
	event: model.Event_Id,
) -> (
	outcome: Outcome,
	found: bool,
) {
	for candidate in index.outcomes {
		if candidate.event == event {
			return candidate, true
		}
	}
	return {}, false
}

// last_comparable_pass returns the most recent passing outcome comparable to
// `target` that occurred before it.
//
// This is the lower bound of the candidate window: docs/06 starts candidate
// mutations at edits since the last comparable passing outcome.
last_comparable_pass :: proc(
	index: ^Outcome_Index,
	target: Outcome,
) -> (
	outcome: Outcome,
	found: bool,
) {
	best: Outcome
	for candidate in index.outcomes {
		if candidate.sequence >= target.sequence {
			break
		}
		if candidate.status != .Passed {
			continue
		}
		if !comparable(candidate, target) {
			continue
		}
		best = candidate
		found = true
	}
	return best, found
}

// Window is the sequence range containing candidate mutations for an outcome.
Window :: struct {
	// Exclusive lower bound: mutations strictly after this sequence qualify.
	from: model.Sequence,
	// Inclusive upper bound: the outcome's own sequence.
	to: model.Sequence,
	// The comparable passing outcome that set the lower bound, when one exists.
	anchor:     model.Event_Id,
	has_anchor: bool,
}

// candidate_window computes the range of mutations that could have contributed
// to an outcome.
//
// docs/06: candidate mutations start with edits since the last comparable
// passing outcome; if no comparable pass exists, the window begins at the
// containing phase or session start. A missing anchor therefore widens the
// window rather than emptying it — the absence of a prior pass is not evidence
// that nothing before could have contributed.
candidate_window :: proc(
	index: ^Outcome_Index,
	trace: ^codec.Trace,
	target: Outcome,
) -> Window {
	window := Window{to = target.sequence}

	if anchor, found := last_comparable_pass(index, target); found {
		window.from = anchor.sequence
		window.anchor = anchor.event
		window.has_anchor = true
		return window
	}

	// No comparable pass: fall back to the containing phase, then session
	// start. Phase boundaries are events, so the most recent phase_start
	// before the outcome bounds the window.
	phase_start := model.Sequence(0)
	for event in trace.events {
		if event.sequence >= target.sequence {
			break
		}
		if event.kind == .Phase_Start {
			phase_start = event.sequence
		}
	}
	window.from = phase_start
	return window
}

// window_contains reports whether a sequence falls inside the window.
window_contains :: proc "contextless" (window: Window, sequence: model.Sequence) -> bool {
	return sequence > window.from && sequence <= window.to
}
