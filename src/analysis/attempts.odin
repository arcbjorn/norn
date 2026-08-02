package analysis

import "src:trace/codec"
import "src:trace/model"

// Attempt and retry-loop detection.
//
// docs/06: an attempt is a derived span beginning with a goal-bearing agent
// message or an outcome, ending at a successful comparable outcome, a new
// explicit goal, a long inactivity boundary, or session end.
//
// docs/06 also states the constraint that shapes this file: attempt detection
// is navigation metadata and does not rewrite original spans. Nothing here
// mutates the trace; the results are a separate index the viewer overlays.

// INACTIVITY_BOUNDARY_NS is the idle duration that ends an attempt.
//
// Five minutes is a starting value, not a measured one. An agent session with
// a longer natural pause will split an attempt that a human would call
// continuous; the boundary is exposed as a parameter so it can be tuned once
// real sessions say what the distribution looks like.
INACTIVITY_BOUNDARY_NS :: i64(5 * 60 * 1_000_000_000)

// Attempt_End records why an attempt stopped, which is as informative as where.
Attempt_End :: enum u8 {
	Session_End       = 0,
	Comparable_Pass   = 1,
	New_Goal          = 2,
	Inactivity        = 3,
}

attempt_end_name :: proc "contextless" (reason: Attempt_End) -> string {
	switch reason {
	case .Session_End:     return "session_end"
	case .Comparable_Pass: return "comparable_pass"
	case .New_Goal:        return "new_goal"
	case .Inactivity:      return "inactivity"
	}
	return "unknown"
}

// Attempt is a derived span over one stretch of work.
Attempt :: struct {
	index:          int,
	start_event:    model.Event_Id,
	end_event:      model.Event_Id,
	start_sequence: model.Sequence,
	end_sequence:   model.Sequence,
	end_reason:     Attempt_End,
	// True when the attempt ended in a comparable pass, which is the only
	// ending that indicates the work succeeded.
	succeeded: bool,
	// Counts for the timeline's aggregated view.
	mutation_count: int,
	outcome_count:  int,
	failure_count:  int,
}

Attempt_Index :: struct {
	attempts: [dynamic]Attempt,
}

attempt_index_destroy :: proc(index: ^Attempt_Index) {
	delete(index.attempts)
	index^ = {}
}

// detect_attempts partitions a session into attempts.
//
// The walk is single-pass and deterministic: every boundary is a property of
// the event stream, never of iteration order or timing during analysis.
detect_attempts :: proc(
	trace: ^codec.Trace,
	outcomes: ^Outcome_Index,
	inactivity_ns := INACTIVITY_BOUNDARY_NS,
	allocator := context.allocator,
) -> Attempt_Index {
	index: Attempt_Index
	index.attempts = make([dynamic]Attempt, 0, 8, allocator)

	if len(trace.events) == 0 {
		return index
	}

	current: Attempt
	open := false
	previous_time := i64(0)
	has_previous_time := false

	flush :: proc(
		index: ^Attempt_Index,
		current: ^Attempt,
		open: ^bool,
		end_event: model.Event_Id,
		end_sequence: model.Sequence,
		reason: Attempt_End,
	) {
		if !open^ {
			return
		}
		current.end_event = end_event
		current.end_sequence = end_sequence
		current.end_reason = reason
		current.succeeded = reason == .Comparable_Pass
		current.index = len(index.attempts)
		append(&index.attempts, current^)
		current^ = {}
		open^ = false
	}

	for event in trace.events {
		is_goal := is_goal_bearing(trace, event)

		// A long idle gap ends the attempt before the event that follows it:
		// the pause belongs to neither side, and attributing it to the new
		// work would make the next attempt look slower than it was.
		if open && has_previous_time && event.wall_time_ns != 0 && previous_time != 0 {
			if event.wall_time_ns - previous_time >= inactivity_ns {
				flush(
					&index,
					&current,
					&open,
					current.end_event,
					current.end_sequence,
					.Inactivity,
				)
			}
		}

		// A new explicit goal ends the previous attempt and starts one.
		if is_goal && open {
			flush(&index, &current, &open, current.end_event, current.end_sequence, .New_Goal)
		}

		if !open {
			// An attempt begins at a goal-bearing message or at an outcome.
			outcome, is_outcome := find_outcome(outcomes, event.id)
			if is_goal || is_outcome {
				current = Attempt {
					start_event    = event.id,
					start_sequence = event.sequence,
					end_event      = event.id,
					end_sequence   = event.sequence,
				}
				open = true
				_ = outcome
			}
		}

		if open {
			current.end_event = event.id
			current.end_sequence = event.sequence
			if model.is_mutation(event.kind) {
				current.mutation_count += 1
			}
			if outcome, found := find_outcome(outcomes, event.id); found {
				current.outcome_count += 1
				if outcome_is_failure(outcome) {
					current.failure_count += 1
				}
				// A passing outcome comparable to a failure inside this
				// attempt closes it: the work it was doing is done.
				if outcome.status == .Passed &&
				   closes_attempt(outcomes, current, outcome) {
					flush(&index, &current, &open, event.id, event.sequence, .Comparable_Pass)
				}
			}
		}

		if event.wall_time_ns != 0 {
			previous_time = event.wall_time_ns
			has_previous_time = true
		}
	}

	flush(&index, &current, &open, current.end_event, current.end_sequence, .Session_End)
	return index
}

// closes_attempt reports whether a passing outcome resolves this attempt.
//
// A pass only closes an attempt when it is comparable to a failure the attempt
// actually contained. A passing test unrelated to the failing work says
// nothing about whether that work succeeded.
@(private)
closes_attempt :: proc(
	outcomes: ^Outcome_Index,
	attempt: Attempt,
	pass: Outcome,
) -> bool {
	if attempt.failure_count == 0 {
		return false
	}
	for candidate in outcomes.outcomes {
		if candidate.sequence < attempt.start_sequence ||
		   candidate.sequence > pass.sequence {
			continue
		}
		if !outcome_is_failure(candidate) {
			continue
		}
		if comparable(candidate, pass) {
			return true
		}
	}
	return false
}

// is_goal_bearing reports whether an event states a new goal.
//
// Only the importer can classify this: it sees the provider's own distinction
// between a user instruction and an incidental message. Analysis reads the
// flag rather than guessing from text, because guessing would make attempt
// boundaries depend on phrasing.
@(private)
is_goal_bearing :: proc(trace: ^codec.Trace, event: model.Event) -> bool {
	if event.kind != .User_Message && event.kind != .Agent_Message {
		return false
	}
	payload, ok := model.get_message(&trace.payloads, event.payload)
	if !ok {
		// Absent a payload, a user message is the closest thing to an explicit
		// goal the trace offers.
		return event.kind == .User_Message
	}
	return payload.goal_bearing
}

// ---------------------------------------------------------------------------
// Retry loops
// ---------------------------------------------------------------------------

// MIN_RETRY_REPEATS is how many identical failures constitute a loop.
//
// Three, not two: a single repeat is ordinary correction, while a third
// identical failure is the pattern a user wants pointed out.
MIN_RETRY_REPEATS :: 3

// Retry_Loop is a run of repeated identical failures.
//
// docs/06 lists this under inferred candidates: repeated identical tool errors
// may form a retry loop. "May" is the operative word, so this is navigation
// metadata rather than a claim that the agent was stuck.
Retry_Loop :: struct {
	first_event:    model.Event_Id,
	last_event:     model.Event_Id,
	start_sequence: model.Sequence,
	end_sequence:   model.Sequence,
	repeats:        int,
	// The signature that repeated, for display.
	signature: model.String_Id,
}

Retry_Index :: struct {
	loops: [dynamic]Retry_Loop,
}

retry_index_destroy :: proc(index: ^Retry_Index) {
	delete(index.loops)
	index^ = {}
}

// detect_retry_loops finds runs of identical repeated failures.
//
// Identity is the interned message identifier, not a similarity measure. Two
// errors are "identical" only when the trace recorded the same string, which
// keeps the detector from grouping distinct failures that merely read alike.
detect_retry_loops :: proc(
	trace: ^codec.Trace,
	allocator := context.allocator,
) -> Retry_Index {
	index: Retry_Index
	index.loops = make([dynamic]Retry_Loop, 0, 4, allocator)

	current: Retry_Loop
	run := 0

	for event in trace.events {
		signature, has_signature := failure_signature(trace, event)
		if !has_signature {
			continue
		}

		if run > 0 && signature == current.signature {
			run += 1
			current.repeats = run
			current.last_event = event.id
			current.end_sequence = event.sequence
			continue
		}

		if run >= MIN_RETRY_REPEATS {
			append(&index.loops, current)
		}

		current = Retry_Loop {
			first_event    = event.id,
			last_event     = event.id,
			start_sequence = event.sequence,
			end_sequence   = event.sequence,
			repeats        = 1,
			signature      = signature,
		}
		run = 1
	}

	if run >= MIN_RETRY_REPEATS {
		append(&index.loops, current)
	}

	return index
}

// failure_signature returns the identity of a repeatable failure.
@(private)
failure_signature :: proc(
	trace: ^codec.Trace,
	event: model.Event,
) -> (
	signature: model.String_Id,
	ok: bool,
) {
	#partial switch event.kind {
	case .Tool_Error:
		if payload, found := model.get_tool(&trace.payloads, event.payload); found {
			if payload.error_message != model.EMPTY_STRING {
				return payload.error_message, true
			}
		}
		return event.summary_string_id, event.summary_string_id != model.EMPTY_STRING

	case .Explicit_Error:
		return event.summary_string_id, event.summary_string_id != model.EMPTY_STRING

	case .Diagnostic:
		if payload, found := model.get_diagnostic(&trace.payloads, event.payload); found {
			if payload.severity >= .Error && payload.message != model.EMPTY_STRING {
				return payload.message, true
			}
		}
	}
	return model.EMPTY_STRING, false
}
