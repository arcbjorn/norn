package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "src:analysis"
import "src:core"
import "src:export"
import "src:trace/codec"
import "src:trace/model"

// `norn export` — write a bounded, redacted diagnostic report.
//
// docs/10 fixes the invocation:
//   norn export <trace.norn> --range <start:end> --out <directory>
//
// docs/08 requires the inclusion manifest to be shown before writing, so the
// manifest is printed first and the files land afterwards. The manifest goes
// to stdout with the result, because a user piping this wants to record what
// they sent, not just that they sent something.

command_export :: proc(arguments: []string) -> int {
	path := ""
	out := ""
	range_text := ""
	focus := u64(0)
	options := export.DEFAULT_OPTIONS

	index := 0
	for index < len(arguments) {
		argument := arguments[index]
		switch argument {
		case "--range":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --range requires start:end")
				return EXIT_USAGE
			}
			range_text = arguments[index]
		case "--out":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --out requires a directory")
				return EXIT_USAGE
			}
			out = arguments[index]
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
			focus = parsed
		case "--include-messages":
			// Opt-in, per docs/01: prompt content is excluded by default.
			options.include_messages = true
		case "--include-output":
			options.include_output = true
		case:
			if strings.has_prefix(argument, "-") {
				fmt.eprintfln("norn: unknown option %q", argument)
				return EXIT_USAGE
			}
			if path != "" {
				fmt.eprintln("norn: export accepts one trace path")
				return EXIT_USAGE
			}
			path = argument
		}
		index += 1
	}

	if path == "" {
		fmt.eprintln("norn: export requires a trace path")
		return EXIT_USAGE
	}
	if out == "" {
		fmt.eprintln("norn: export requires --out <directory>")
		return EXIT_USAGE
	}

	from, to, range_ok := parse_range(range_text)
	if !range_ok {
		fmt.eprintfln("norn: %q is not a valid range; use start:end", range_text)
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

	if focus != 0 {
		if _, is_outcome := analysis.find_outcome(&outcomes, model.Event_Id(focus)); !is_outcome {
			fmt.eprintfln("norn: event %d is not an outcome in this trace", focus)
			return EXIT_INVALID_TRACE
		}
	}

	bundle := export.build_bundle(
		&trace,
		&outcomes,
		from,
		to,
		model.Event_Id(focus),
		options,
	)
	defer export.bundle_destroy(&bundle)

	// docs/08: show the manifest before export.
	print_export_manifest(&bundle)

	if write_err := export.write_bundle(&bundle, out); !core.ok(write_err) {
		report_error(out, write_err)
		return exit_code_for(write_err)
	}

	fmt.printfln("wrote %s/%s", out, export.REPORT_NAME)
	fmt.printfln("wrote %s/%s", out, export.DATA_NAME)
	return EXIT_OK
}

// parse_range reads `start:end`. An empty argument means the whole session,
// which is the only sensible default for a range nobody specified.
@(private)
parse_range :: proc(text: string) -> (from: model.Sequence, to: model.Sequence, ok: bool) {
	if text == "" {
		return 0, max(model.Sequence), true
	}

	separator := strings.index_byte(text, ':')
	if separator < 0 {
		return 0, 0, false
	}

	start_text := text[:separator]
	end_text := text[separator + 1:]

	start := u64(0)
	if start_text != "" {
		parsed, parsed_ok := strconv.parse_u64(start_text)
		if !parsed_ok {
			return 0, 0, false
		}
		start = parsed
	}

	end := u64(max(u64))
	if end_text != "" {
		parsed, parsed_ok := strconv.parse_u64(end_text)
		if !parsed_ok {
			return 0, 0, false
		}
		end = parsed
	}

	if start > end {
		return 0, 0, false
	}
	return model.Sequence(start), model.Sequence(end), true
}

@(private)
print_export_manifest :: proc(bundle: ^export.Bundle) {
	manifest := &bundle.manifest

	fmt.println("this export will include:")
	print_manifest_line("prompt and response text", manifest.has_prompt_text)
	print_manifest_line("file paths", manifest.has_file_paths)
	print_manifest_line("diffs", manifest.has_diffs)
	print_manifest_line("command lines", manifest.has_command_lines)
	print_manifest_line("command output", manifest.has_command_output)
	print_manifest_line("repository metadata", manifest.has_repository_metadata)
	print_manifest_line("raw provider records", manifest.has_raw_records)
	print_manifest_line("annotations", manifest.has_annotations)

	fmt.println()
	fmt.printfln("  %d events, %d outcomes, %d changes, %d candidates, %d edges",
		manifest.event_count,
		manifest.outcome_count,
		manifest.change_count,
		manifest.candidate_count,
		manifest.edge_count,
	)
	if manifest.truncated_values > 0 {
		fmt.printfln("  %d value(s) shortened and marked incomplete", manifest.truncated_values)
	}

	total_redactions := 0
	for count in manifest.redactions_by_category {
		total_redactions += int(count)
	}
	if total_redactions > 0 {
		fmt.printfln("  %d redaction(s) were applied at import", total_redactions)
	}
	fmt.println()
}

@(private)
print_manifest_line :: proc(label: string, included: bool) {
	fmt.printfln("  [%s] %s", "x" if included else " ", label)
}
