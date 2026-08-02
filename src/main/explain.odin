package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "src:analysis"
import "src:core"
import "src:trace/codec"
import "src:trace/model"

// `norn explain` — the evidence stack for a selected outcome.
//
// docs/01: selecting an outcome opens an evidence stack, and the interface
// says "candidate contributor", "preceded", or "affected" unless an explicit
// trace relationship establishes stronger semantics. This command is the
// terminal rendering of that rule, and its wording is chosen to obey it.

command_explain :: proc(arguments: []string) -> int {
	path := ""
	event_id := u64(0)
	list_only := false

	index := 0
	for index < len(arguments) {
		argument := arguments[index]
		switch argument {
		case "--event":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --event requires an event identifier")
				return EXIT_USAGE
			}
			parsed, ok := strconv.parse_u64(arguments[index])
			if !ok || parsed == 0 {
				fmt.eprintfln("norn: %q is not an event identifier", arguments[index])
				return EXIT_USAGE
			}
			event_id = parsed
		case "--list":
			list_only = true
		case:
			if strings.has_prefix(argument, "-") {
				fmt.eprintfln("norn: unknown option %q", argument)
				return EXIT_USAGE
			}
			if path != "" {
				fmt.eprintln("norn: explain accepts one trace path")
				return EXIT_USAGE
			}
			path = argument
		}
		index += 1
	}

	if path == "" {
		fmt.eprintln("norn: explain requires a trace path")
		return EXIT_USAGE
	}
	if event_id == 0 && !list_only {
		fmt.eprintln("norn: explain requires --event <id>, or --list to see outcomes")
		return EXIT_USAGE
	}

	data, code := read_trace_file(path)
	if code != EXIT_OK {
		return code
	}
	defer delete(data)

	trace, err := codec.open_trace(data)
	if !core.ok(err) {
		report_error(path, err)
		return exit_code_for(err)
	}
	defer codec.trace_destroy(&trace)

	outcomes := analysis.build_outcome_index(&trace)
	defer analysis.outcome_index_destroy(&outcomes)

	if list_only {
		print_outcome_list(&trace, &outcomes)
		return EXIT_OK
	}

	target, found := analysis.find_outcome(&outcomes, model.Event_Id(event_id))
	if !found {
		fmt.eprintfln("norn: event %d is not an outcome in this trace", event_id)
		fmt.eprintln("norn: use --list to see selectable outcomes")
		return EXIT_INVALID_TRACE
	}

	input := analysis.Scoring_Input{trace = &trace, outcomes = &outcomes}
	ranking := analysis.score_outcome(input, target)
	defer analysis.ranking_destroy(&ranking)

	stack := analysis.build_evidence_stack(input, target, &ranking)
	defer analysis.evidence_stack_destroy(&stack)

	print_evidence_stack(&trace, &stack, &ranking)
	return EXIT_OK
}

@(private)
print_outcome_list :: proc(trace: ^codec.Trace, outcomes: ^analysis.Outcome_Index) {
	if len(outcomes.outcomes) == 0 {
		fmt.println("this trace records no outcomes")
		return
	}

	fmt.printfln("%-8s %-10s %-10s %s", "event", "kind", "status", "subject")
	for outcome in outcomes.outcomes {
		subject := entity_name(trace, outcome_subject(outcome))
		fmt.printfln(
			"%-8s %-10s %-10s %s",
			fmt.tprintf("%d", u64(outcome.event)),
			analysis.outcome_kind_name(outcome.kind),
			model.outcome_status_name(outcome.status),
			subject,
		)
	}
}

@(private)
outcome_subject :: proc(outcome: analysis.Outcome) -> model.Entity_Id {
	if outcome.test_case != model.NO_ENTITY {
		return outcome.test_case
	}
	return outcome.command
}

@(private)
entity_name :: proc(trace: ^codec.Trace, id: model.Entity_Id) -> string {
	if id == model.NO_ENTITY {
		return "-"
	}
	index := int(id) - 1
	if index < 0 || index >= len(trace.entities) {
		return "-"
	}
	name, ok := model.string_get(&trace.strings, trace.entities[index].name)
	if !ok || name == "" {
		return "-"
	}
	return name
}

@(private)
print_evidence_stack :: proc(
	trace: ^codec.Trace,
	stack: ^analysis.Evidence_Stack,
	ranking: ^analysis.Ranking,
) {
	target := stack.outcome

	fmt.printfln(
		"outcome %d: %s %s (%s)",
		u64(target.event),
		analysis.outcome_kind_name(target.kind),
		model.outcome_status_name(target.status),
		entity_name(trace, outcome_subject(target)),
	)

	if stack.window.has_anchor {
		fmt.printfln(
			"window:  events after the last comparable pass (event %d)",
			u64(stack.window.anchor),
		)
	} else {
		fmt.println("window:  no comparable passing outcome; from phase or session start")
	}
	fmt.println()

	// Recorded and mechanically derived evidence first, so a reader meets the
	// facts before the hypotheses.
	fmt.println("evidence")
	for entry in stack.entries {
		if entry.level == .Inferred {
			continue
		}
		location := entity_name(trace, entry.path)
		suffix := "" if location == "-" else fmt.tprintf(" [%s]", location)
		fmt.printfln(
			"  %-14s event %-5s %s%s",
			analysis.evidence_level_name(entry.level),
			fmt.tprintf("%d", u64(entry.event)),
			entry.label,
			suffix,
		)
	}
	fmt.println()

	// Candidates are labeled as candidates. docs/01 forbids calling them
	// causes, and the header says so rather than leaving it to the reader.
	if len(ranking.candidates) == 0 {
		fmt.println("candidate contributors: none")
	} else {
		fmt.println("candidate contributors (ranked, not causes)")
		for candidate in ranking.candidates {
			fmt.printfln(
				"  %.2f  event %-5s %s%s",
				f64(model.confidence_to_f32(candidate.score)),
				fmt.tprintf("%d", u64(candidate.mutation_event)),
				entity_name(trace, candidate.path),
				" [capped by replay gap]" if candidate.gap_capped else "",
			)
			// Every score expands into its deterministic contributions, which
			// docs/11 makes an exit criterion for this phase.
			for rule in analysis.Rule {
				if rule not_in candidate.rules {
					continue
				}
				fmt.printfln(
					"          %s: %s",
					analysis.rule_id(rule),
					analysis.rule_reason(rule),
				)
			}
		}
	}

	if len(stack.uncertainties) > 0 {
		fmt.println()
		fmt.println("uncertainty")
		for note in stack.uncertainties {
			fmt.printfln("  %s", note)
		}
	}
}
