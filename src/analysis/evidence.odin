package analysis

import "src:trace/codec"
import "src:trace/model"

// Evidence edges and the evidence stack.
//
// docs/06 separates analysis into three levels, and docs/01 requires the
// interface to say "candidate contributor", "preceded", or "affected" unless
// an explicit trace relationship establishes stronger semantics. Every edge
// this file produces carries the origin that licenses its wording.

// build_evidence_edges derives the reconstructed and inferred edges for a
// trace, leaving explicit edges as the importer recorded them.
//
// Derived edges are appended to a caller-owned slice rather than written into
// the trace: decision 005 makes a completed trace immutable, and docs/06 makes
// derived data rebuildable and discardable.
build_evidence_edges :: proc(
	trace: ^codec.Trace,
	outcomes: ^Outcome_Index,
	allocator := context.allocator,
) -> [dynamic]model.Edge {
	edges := make([dynamic]model.Edge, 0, 32, allocator)

	build_reconstructed_edges(trace, &edges)
	build_writes_edges(trace, &edges)
	build_diagnoses_edges(trace, &edges)

	return edges
}

// build_reconstructed_edges links events to the command span containing them.
//
// docs/06 mechanical reconstruction: events within one command span. This
// follows deterministically from canonical facts, so the origin is
// Reconstructed and the confidence is full — it is not a guess, it is a
// restatement of recorded structure.
@(private)
build_reconstructed_edges :: proc(trace: ^codec.Trace, edges: ^[dynamic]model.Edge) {
	for event in trace.events {
		if event.parent_span_id == model.NO_SPAN {
			continue
		}
		index := int(event.parent_span_id) - 1
		if index < 0 || index >= len(trace.spans) {
			continue
		}
		span := trace.spans[index]
		if span.kind != .Command_Execution && span.kind != .Tool_Invocation {
			continue
		}
		if span.start_event == model.NO_EVENT || span.start_event == event.id {
			continue
		}

		append(
			edges,
			model.Edge {
				kind = .Parent,
				origin = .Reconstructed,
				from = model.event_endpoint(span.start_event),
				to = model.event_endpoint(event.id),
				confidence = model.CONFIDENCE_SCALE,
			},
		)
	}
}

// build_writes_edges links each mutation event to the path it changed.
//
// docs/06 explicit structure: a mutation names a path. The relationship is
// recorded in the mutation itself, so the edge restates a fact rather than
// deriving one, and the origin is Explicit.
@(private)
build_writes_edges :: proc(trace: ^codec.Trace, edges: ^[dynamic]model.Edge) {
	for mutation in trace.mutations {
		if mutation.path == model.NO_ENTITY {
			continue
		}
		append(
			edges,
			model.Edge {
				kind = .Writes,
				origin = .Explicit,
				from = model.event_endpoint(mutation.event_id),
				to = model.entity_endpoint(mutation.path),
				confidence = model.CONFIDENCE_SCALE,
			},
		)
		if mutation.op == .Rename && mutation.old_path != model.NO_ENTITY {
			append(
				edges,
				model.Edge {
					kind = .Renames,
					origin = .Explicit,
					from = model.entity_endpoint(mutation.old_path),
					to = model.entity_endpoint(mutation.path),
					confidence = model.CONFIDENCE_SCALE,
				},
			)
		}
	}
}

// build_diagnoses_edges links diagnostics to the paths they name.
//
// docs/06 explicit structure: a diagnostic names a path and line.
@(private)
build_diagnoses_edges :: proc(trace: ^codec.Trace, edges: ^[dynamic]model.Edge) {
	for event in trace.events {
		if event.kind != .Diagnostic {
			continue
		}
		payload, ok := model.get_diagnostic(&trace.payloads, event.payload)
		if !ok || payload.path == model.NO_ENTITY {
			continue
		}
		append(
			edges,
			model.Edge {
				kind = .Diagnoses,
				origin = .Explicit,
				from = model.event_endpoint(event.id),
				to = model.entity_endpoint(payload.path),
				confidence = model.CONFIDENCE_SCALE,
			},
		)
	}
}

// candidate_edges converts a ranking into inferred edges.
//
// docs/03 requires an inferred edge to carry confidence, a rule identifier,
// and a human-readable reason. The rule identifier here names the highest
// weighted contributing signal, because a single identifier must point at the
// strongest reason the candidate ranked where it did; the full rule set stays
// available on the Candidate for the expanded view.
candidate_edges :: proc(
	ranking: ^Ranking,
	strings: ^model.String_Table,
	allocator := context.allocator,
) -> [dynamic]model.Edge {
	edges := make([dynamic]model.Edge, 0, len(ranking.candidates), allocator)

	for candidate in ranking.candidates {
		rule, has_rule := dominant_rule(candidate.rules)
		if !has_rule {
			continue
		}
		rule_string, _ := model.string_intern(strings, rule_id(rule))
		reason_string, _ := model.string_intern(strings, rule_reason(rule))

		append(
			&edges,
			model.Edge {
				kind = .Candidate_Contributor,
				origin = .Inferred,
				from = model.event_endpoint(candidate.mutation_event),
				to = model.event_endpoint(ranking.outcome),
				confidence = candidate.score,
				rule = rule_string,
				reason = reason_string,
			},
		)
	}
	return edges
}

// dominant_rule returns the highest-weighted rule in a set.
@(private)
dominant_rule :: proc "contextless" (rules: Rule_Set) -> (rule: Rule, found: bool) {
	best := Rule.Diagnostic_Names_Path
	best_weight := -1
	for candidate in Rule {
		if candidate not_in rules {
			continue
		}
		weight := rule_weight(candidate)
		if weight > best_weight {
			best = candidate
			best_weight = weight
		}
	}
	return best, best_weight >= 0
}

// Evidence_Level restates the three analysis layers for display.
Evidence_Level :: enum u8 {
	Explicit      = 0,
	Reconstructed = 1,
	Inferred      = 2,
}

evidence_level_name :: proc "contextless" (level: Evidence_Level) -> string {
	switch level {
	case .Explicit:      return "explicit"
	case .Reconstructed: return "reconstructed"
	case .Inferred:      return "inferred"
	}
	return "unknown"
}

// Stack_Entry is one item in an outcome's evidence stack.
Stack_Entry :: struct {
	level: Evidence_Level,
	event: model.Event_Id,
	// The path this entry concerns, when it concerns one.
	path: model.Entity_Id,
	// Populated for inferred entries.
	score: model.Confidence,
	rules: Rule_Set,
	gap_capped: bool,
	// A short label describing why this entry is in the stack.
	label: string,
}

// Evidence_Stack is the ordered evidence for a selected outcome.
//
// docs/01 fixes the order: the outcome itself, directly attached parent
// events, mutations since the last comparable success, reads and tool results
// associated with those mutations, inferred contributor candidates ordered by
// confidence, and finally uncertainty and missing evidence.
Evidence_Stack :: struct {
	outcome: Outcome,
	window:  Window,
	entries: [dynamic]Stack_Entry,
	// Statements about what is not known, which docs/01 requires the stack to
	// surface rather than omit.
	uncertainties: [dynamic]string,
}

evidence_stack_destroy :: proc(stack: ^Evidence_Stack) {
	delete(stack.entries)
	delete(stack.uncertainties)
	stack^ = {}
}

// build_evidence_stack assembles the evidence for one outcome.
build_evidence_stack :: proc(
	input: Scoring_Input,
	target: Outcome,
	ranking: ^Ranking,
	allocator := context.allocator,
) -> Evidence_Stack {
	stack := Evidence_Stack {
		outcome       = target,
		window        = ranking.window,
		entries       = make([dynamic]Stack_Entry, 0, 16, allocator),
		uncertainties = make([dynamic]string, 0, 4, allocator),
	}

	// 1. The outcome itself.
	append(
		&stack.entries,
		Stack_Entry{level = .Explicit, event = target.event, label = "the selected outcome"},
	)

	// 2. Directly attached parent events.
	if target.span != model.NO_SPAN {
		index := int(target.span) - 1
		if index >= 0 && index < len(input.trace.spans) {
			span := input.trace.spans[index]
			if span.start_event != model.NO_EVENT && span.start_event != target.event {
				append(
					&stack.entries,
					Stack_Entry {
						level = .Explicit,
						event = span.start_event,
						label = "the operation containing this outcome",
					},
				)
			}
		}
	}

	// 3. Mutations since the last comparable success.
	for mutation in input.trace.mutations {
		sequence, ok := mutation_sequence(input.trace, mutation)
		if !ok || !window_contains(ranking.window, sequence) {
			continue
		}
		append(
			&stack.entries,
			Stack_Entry {
				level = .Reconstructed,
				event = mutation.event_id,
				path = mutation.path,
				label = "changed a file within the comparison window",
			},
		)
	}

	// 4. Reads and tool results associated with those mutations.
	for event in input.trace.events {
		if event.kind != .File_Read && event.kind != .Tool_Result {
			continue
		}
		if !window_contains(ranking.window, event.sequence) {
			continue
		}
		append(
			&stack.entries,
			Stack_Entry {
				level = .Reconstructed,
				event = event.id,
				path = event.primary_entity_id,
				label = "observed within the comparison window",
			},
		)
	}

	// 5. Inferred contributor candidates, ordered by confidence.
	for candidate in ranking.candidates {
		append(
			&stack.entries,
			Stack_Entry {
				level = .Inferred,
				event = candidate.mutation_event,
				path = candidate.path,
				score = candidate.score,
				rules = candidate.rules,
				gap_capped = candidate.gap_capped,
				label = "candidate contributor",
			},
		)
	}

	// 6. Uncertainty and missing evidence.
	if ranking.unanchored {
		append(
			&stack.uncertainties,
			"no comparable passing outcome precedes this failure, so the window begins at the containing phase or session start",
		)
	}
	if len(ranking.candidates) == 0 {
		append(
			&stack.uncertainties,
			"no mutation in the window carries evidence linking it to this outcome",
		)
	}
	for candidate in ranking.candidates {
		if candidate.gap_capped {
			append(
				&stack.uncertainties,
				"a replay gap limits confidence for at least one candidate",
			)
			break
		}
	}

	return stack
}
