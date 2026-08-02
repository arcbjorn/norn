package export

import "core:fmt"
import "core:strings"

import "src:trace/codec"
import "src:trace/model"

// Canonical JSON rendering.
//
// docs/01: an export contains a human-readable HTML report and canonical JSON
// data. "Canonical" is the operative word: keys are written in a fixed order
// and numbers in a fixed format, so two exports of the same range produce
// byte-identical JSON and a reviewer can diff them.
//
// Nothing here iterates a map. docs/10 forbids relying on map iteration order,
// and an export whose key order varied between runs would be undiffable.

// JSON_SCHEMA_VERSION identifies the shape of the emitted document. A consumer
// can branch on it rather than guessing from which keys are present.
JSON_SCHEMA_VERSION :: 1

// render_json writes the bundle as canonical JSON. The caller owns the result.
render_json :: proc(bundle: ^Bundle, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)

	strings.write_string(&builder, "{\n")
	write_field_int(&builder, 1, "schema_version", JSON_SCHEMA_VERSION, true)

	// Session and importer metadata.
	indent(&builder, 1)
	strings.write_string(&builder, `"session": {`)
	strings.write_byte(&builder, '\n')
	write_field_string(&builder, 2, "importer_id", bundle.importer_id, true)
	write_field_string(&builder, 2, "importer_version", bundle.importer_version, true)
	write_field_string(&builder, 2, "repository", bundle.repository_name, true)
	write_field_string(&builder, 2, "baseline", bundle.baseline_kind, true)
	indent(&builder, 2)
	fmt.sbprintf(
		&builder,
		`"format": {{"major": %d, "minor": %d}}`,
		bundle.format_major,
		bundle.format_minor,
	)
	strings.write_byte(&builder, '\n')
	indent(&builder, 1)
	strings.write_string(&builder, "},\n")

	// The selected range.
	indent(&builder, 1)
	fmt.sbprintf(
		&builder,
		`"range": {{"from": %d, "to": %d}},`,
		u64(bundle.range_from),
		u64(bundle.range_to),
	)
	strings.write_byte(&builder, '\n')

	// The outcome this export explains.
	indent(&builder, 1)
	strings.write_string(&builder, `"focus": `)
	if bundle.has_focus_outcome {
		fmt.sbprintf(&builder, `{{"outcome_event": %d`, u64(bundle.focus_outcome))
		if bundle.has_window_anchor {
			fmt.sbprintf(&builder, `, "window_anchor_event": %d`, u64(bundle.window_anchor))
		} else {
			strings.write_string(&builder, `, "window_anchor_event": null`)
		}
		strings.write_string(&builder, "},\n")
	} else {
		strings.write_string(&builder, "null,\n")
	}

	write_manifest(&builder, bundle)
	write_events(&builder, bundle)
	write_outcomes(&builder, bundle)
	write_changes(&builder, bundle)
	write_candidates(&builder, bundle)
	write_edges(&builder, bundle)
	write_uncertainties(&builder, bundle)

	strings.write_string(&builder, "}\n")
	return strings.to_string(builder)
}

@(private)
indent :: proc(builder: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(builder, "  ")
	}
}

@(private)
write_field_string :: proc(
	builder: ^strings.Builder,
	depth: int,
	key: string,
	value: string,
	comma: bool,
) {
	indent(builder, depth)
	write_json_string(builder, key)
	strings.write_string(builder, ": ")
	write_json_string(builder, value)
	if comma {
		strings.write_byte(builder, ',')
	}
	strings.write_byte(builder, '\n')
}

@(private)
write_field_int :: proc(
	builder: ^strings.Builder,
	depth: int,
	key: string,
	value: int,
	comma: bool,
) {
	indent(builder, depth)
	write_json_string(builder, key)
	fmt.sbprintf(builder, ": %d", value)
	if comma {
		strings.write_byte(builder, ',')
	}
	strings.write_byte(builder, '\n')
}

@(private)
write_field_bool :: proc(
	builder: ^strings.Builder,
	depth: int,
	key: string,
	value: bool,
	comma: bool,
) {
	indent(builder, depth)
	write_json_string(builder, key)
	strings.write_string(builder, ": ")
	strings.write_string(builder, "true" if value else "false")
	if comma {
		strings.write_byte(builder, ',')
	}
	strings.write_byte(builder, '\n')
}

@(private)
write_manifest :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	manifest := &bundle.manifest

	indent(builder, 1)
	strings.write_string(builder, "\"manifest\": {\n")

	// docs/08 lists exactly these inclusion categories.
	write_field_bool(builder, 2, "prompt_text", manifest.has_prompt_text, true)
	write_field_bool(builder, 2, "file_paths", manifest.has_file_paths, true)
	write_field_bool(builder, 2, "diffs", manifest.has_diffs, true)
	write_field_bool(builder, 2, "command_lines", manifest.has_command_lines, true)
	write_field_bool(builder, 2, "command_output", manifest.has_command_output, true)
	write_field_bool(builder, 2, "repository_metadata", manifest.has_repository_metadata, true)
	write_field_bool(builder, 2, "raw_records", manifest.has_raw_records, true)
	write_field_bool(builder, 2, "annotations", manifest.has_annotations, true)

	write_field_int(builder, 2, "events", manifest.event_count, true)
	write_field_int(builder, 2, "outcomes", manifest.outcome_count, true)
	write_field_int(builder, 2, "changes", manifest.change_count, true)
	write_field_int(builder, 2, "candidates", manifest.candidate_count, true)
	write_field_int(builder, 2, "edges", manifest.edge_count, true)
	write_field_int(builder, 2, "truncated_values", manifest.truncated_values, true)

	// Counts by category, in enum order rather than map order.
	indent(builder, 2)
	strings.write_string(builder, "\"import_warnings\": {\n")
	first := true
	for category in codec.Warning_Category {
		count := manifest.warnings_by_category[int(category)]
		if count == 0 {
			continue
		}
		if !first {
			strings.write_string(builder, ",\n")
		}
		indent(builder, 3)
		write_json_string(builder, codec.warning_category_name(category))
		fmt.sbprintf(builder, ": %d", count)
		first = false
	}
	if !first {
		strings.write_byte(builder, '\n')
	}
	indent(builder, 2)
	strings.write_string(builder, "},\n")

	indent(builder, 2)
	strings.write_string(builder, "\"redactions\": {\n")
	first = true
	for category in codec.Redaction_Category {
		count := manifest.redactions_by_category[int(category)]
		if count == 0 {
			continue
		}
		if !first {
			strings.write_string(builder, ",\n")
		}
		indent(builder, 3)
		write_json_string(builder, codec.redaction_category_name(category))
		fmt.sbprintf(builder, ": %d", count)
		first = false
	}
	if !first {
		strings.write_byte(builder, '\n')
	}
	indent(builder, 2)
	strings.write_string(builder, "}\n")

	indent(builder, 1)
	strings.write_string(builder, "},\n")
}

@(private)
write_events :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	strings.write_string(builder, "\"events\": [\n")
	for event, index in bundle.events {
		indent(builder, 2)
		strings.write_string(builder, "{")
		fmt.sbprintf(builder, `"id": %d, "sequence": %d, `, u64(event.id), u64(event.sequence))
		strings.write_string(builder, `"kind": `)
		write_json_string(builder, fmt.tprintf("%v", event.kind))

		if event.has_wall_time {
			fmt.sbprintf(builder, `, "wall_time_ns": %d`, event.wall_time_ns)
		} else {
			strings.write_string(builder, `, "wall_time_ns": null`)
		}
		if event.has_duration {
			fmt.sbprintf(builder, `, "duration_ns": %d`, event.duration_ns)
		}
		if event.path != "" {
			strings.write_string(builder, `, "path": `)
			write_json_string(builder, event.path)
		}
		if event.summary != "" {
			strings.write_string(builder, `, "summary": `)
			write_json_string(builder, event.summary)
		}
		strings.write_string(builder, "}")
		if index < len(bundle.events) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "],\n")
}

@(private)
write_outcomes :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	strings.write_string(builder, "\"outcomes\": [\n")
	for outcome, index in bundle.outcomes {
		indent(builder, 2)
		fmt.sbprintf(builder, `{{"event": %d, `, u64(outcome.event))
		strings.write_string(builder, `"kind": `)
		write_json_string(builder, outcome.kind)
		strings.write_string(builder, `, "status": `)
		write_json_string(builder, outcome.status)
		strings.write_string(builder, `, "subject": `)
		write_json_string(builder, outcome.subject)
		strings.write_string(builder, "}")
		if index < len(bundle.outcomes) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "],\n")
}

@(private)
write_changes :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	strings.write_string(builder, "\"changes\": [\n")
	for change, index in bundle.changes {
		indent(builder, 2)
		strings.write_string(builder, `{"path": `)
		write_json_string(builder, change.path)
		strings.write_string(builder, `, "change": `)
		write_json_string(builder, change.kind)
		strings.write_string(builder, `, "affected_by_replay_gap": `)
		strings.write_string(builder, "true" if change.affected_by_gap else "false")
		strings.write_string(builder, "}")
		if index < len(bundle.changes) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "],\n")
}

@(private)
write_candidates :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	// The key names what these are. docs/01 forbids calling them causes, and
	// a machine consumer reads the key rather than the prose.
	strings.write_string(builder, "\"candidate_contributors\": [\n")
	for candidate, index in bundle.candidates {
		indent(builder, 2)
		fmt.sbprintf(builder, `{{"mutation_event": %d, `, u64(candidate.mutation_event))
		strings.write_string(builder, `"path": `)
		write_json_string(builder, candidate.path)
		// Two decimals: the score ranks candidates and is not a probability,
		// so more precision would imply an accuracy it does not have.
		fmt.sbprintf(builder, `, "score": %.2f`, f64(candidate.score))
		strings.write_string(builder, `, "capped_by_replay_gap": `)
		strings.write_string(builder, "true" if candidate.gap_capped else "false")

		strings.write_string(builder, `, "rules": [`)
		for rule, rule_index in candidate.rules {
			strings.write_string(builder, "{\"id\": ")
			write_json_string(builder, rule.id)
			strings.write_string(builder, ", \"reason\": ")
			write_json_string(builder, rule.reason)
			strings.write_string(builder, "}")
			if rule_index < len(candidate.rules) - 1 {
				strings.write_string(builder, ", ")
			}
		}
		strings.write_string(builder, "]}")
		if index < len(bundle.candidates) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "],\n")
}

@(private)
write_edges :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	strings.write_string(builder, "\"evidence_edges\": [\n")
	for edge, index in bundle.edges {
		indent(builder, 2)
		strings.write_string(builder, `{"kind": `)
		write_json_string(builder, edge.kind)
		// The origin is mandatory in the output because a consumer must be
		// able to distinguish recorded facts from derived guesses.
		strings.write_string(builder, `, "origin": `)
		write_json_string(builder, edge.origin)
		fmt.sbprintf(builder, `, "from_event": %d`, u64(edge.from_event))
		if edge.to_event != model.NO_EVENT {
			fmt.sbprintf(builder, `, "to_event": %d`, u64(edge.to_event))
		}
		fmt.sbprintf(builder, `, "confidence": %.2f`, f64(edge.confidence))
		if edge.rule != "" {
			strings.write_string(builder, `, "rule": `)
			write_json_string(builder, edge.rule)
		}
		if edge.reason != "" {
			strings.write_string(builder, `, "reason": `)
			write_json_string(builder, edge.reason)
		}
		strings.write_string(builder, "}")
		if index < len(bundle.edges) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "],\n")
}

@(private)
write_uncertainties :: proc(builder: ^strings.Builder, bundle: ^Bundle) {
	indent(builder, 1)
	strings.write_string(builder, "\"uncertainties\": [\n")
	for note, index in bundle.uncertainties {
		indent(builder, 2)
		write_json_string(builder, note)
		if index < len(bundle.uncertainties) - 1 {
			strings.write_byte(builder, ',')
		}
		strings.write_byte(builder, '\n')
	}
	indent(builder, 1)
	strings.write_string(builder, "]\n")
}
