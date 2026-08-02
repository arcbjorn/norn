package main

import "core:fmt"
import "core:os"
import "core:strings"

import "src:core"
import "src:replay"
import "src:trace/codec"
import "src:trace/model"

// `norn inspect` and `norn validate`.
//
// docs/10-development.md: machine-readable output goes to stdout, diagnostics
// to stderr, and exit codes are explicit. `--json` therefore emits nothing but
// JSON on stdout, so it can be piped without filtering.

// read_trace_file loads a trace and maps I/O failures to exit codes.
@(private)
read_trace_file :: proc(path: string) -> (data: []byte, code: int) {
	contents, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("norn: cannot read %q: %v", path, err)
		return nil, EXIT_INPUT_ERROR
	}
	return contents, EXIT_OK
}

// exit_code_for maps an error category to the CLI's exit contract.
@(private)
exit_code_for :: proc(err: core.Error) -> int {
	#partial switch core.error_category(err) {
	case .None:
		return EXIT_OK
	case .Unsupported_Version, .Unsupported_Feature:
		return EXIT_UNSUPPORTED
	case .Io_Failure, .Not_Found, .Permission_Denied:
		return EXIT_INPUT_ERROR
	case .Invalid_Argument:
		return EXIT_USAGE
	}
	return EXIT_INVALID_TRACE
}

// report_error prints a failure to stderr in a stable, greppable shape.
@(private)
report_error :: proc(path: string, err: core.Error) {
	failure := core.failure(err)
	category := core.category_name(failure.category)

	switch failure.subject.kind {
	case .None:
		fmt.eprintfln("norn: %s: %s: %s", path, category, failure.message)
	case .Path:
		fmt.eprintfln(
			"norn: %s: %s: %s (path %s)",
			path,
			category,
			failure.message,
			failure.subject.text,
		)
	case .Byte_Offset:
		fmt.eprintfln(
			"norn: %s: %s: %s (offset %d)",
			path,
			category,
			failure.message,
			failure.subject.number,
		)
	case .Record_Number:
		fmt.eprintfln(
			"norn: %s: %s: %s (record %d)",
			path,
			category,
			failure.message,
			failure.subject.number,
		)
	case .Event_Id:
		fmt.eprintfln(
			"norn: %s: %s: %s (event %d)",
			path,
			category,
			failure.message,
			failure.subject.number,
		)
	case .Chunk_Ordinal:
		fmt.eprintfln(
			"norn: %s: %s: %s (chunk %d)",
			path,
			category,
			failure.message,
			failure.subject.number,
		)
	}
}

command_validate :: proc(arguments: []string) -> int {
	path := ""
	mode := codec.Validation_Mode.Quick

	index := 0
	for index < len(arguments) {
		argument := arguments[index]
		switch argument {
		case "--mode":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --mode requires a value")
				return EXIT_USAGE
			}
			switch arguments[index] {
			case "quick":  mode = .Quick
			case "full":   mode = .Full
			case "replay": mode = .Replay
			case:
				fmt.eprintfln("norn: unknown validation mode %q", arguments[index])
				return EXIT_USAGE
			}
		case:
			if strings.has_prefix(argument, "-") {
				fmt.eprintfln("norn: unknown option %q", argument)
				return EXIT_USAGE
			}
			if path != "" {
				fmt.eprintln("norn: validate accepts one trace path")
				return EXIT_USAGE
			}
			path = argument
		}
		index += 1
	}

	if path == "" {
		fmt.eprintln("norn: validate requires a trace path")
		return EXIT_USAGE
	}

	data, code := read_trace_file(path)
	if code != EXIT_OK {
		return code
	}
	defer delete(data)

	// Replay mode is full validation plus reconstruction of every mutation
	// chain, so the structural checks run first and only then the replay pass.
	check_mode := mode if mode != .Replay else codec.Validation_Mode.Full
	err := codec.validate(data, check_mode)
	if !core.ok(err) {
		report_error(path, err)
		return exit_code_for(err)
	}

	if mode == .Replay {
		return command_validate_replay(path, data)
	}

	mode_name := "quick" if mode == .Quick else "full"
	fmt.printfln("%s: valid (%s)", path, mode_name)
	return EXIT_OK
}

// command_validate_replay reconstructs every mutation chain and reports what
// could and could not be replayed.
//
// A trace containing gaps still exits zero: docs/03 treats the gap statuses as
// legitimate recorded outcomes, and a session whose provider omitted content
// is faithfully recorded, not corrupt. The counts go to stdout so the result
// is greppable, and exit codes stay reserved for the file being unusable.
@(private)
command_validate_replay :: proc(path: string, data: []byte) -> int {
	trace, err := codec.open_trace(data)
	if !core.ok(err) {
		report_error(path, err)
		return exit_code_for(err)
	}
	defer codec.trace_destroy(&trace)

	report, replay_err := replay.validate_replay(&trace)
	if !core.ok(replay_err) {
		report_error(path, replay_err)
		return exit_code_for(replay_err)
	}

	fmt.printfln("%s: valid (replay)", path)
	fmt.printfln("  mutations:  %d", report.mutations)
	fmt.printfln("  verified:   %d", report.verified)
	fmt.printfln("  unverified: %d", report.unverified)
	if report.binary > 0 {
		fmt.printfln("  binary:     %d", report.binary)
	}

	if report.gaps > 0 {
		// Gaps are the point of the exercise, so they are stated plainly
		// rather than buried under a success line.
		fmt.printfln("  gaps:       %d", report.gaps)
		if report.missing_baseline > 0 {
			fmt.printfln("    missing_baseline:  %d", report.missing_baseline)
		}
		if report.unsupported_patch > 0 {
			fmt.printfln("    unsupported_patch: %d", report.unsupported_patch)
		}
		if report.hash_mismatch > 0 {
			fmt.printfln("    hash_mismatch:     %d", report.hash_mismatch)
		}
		fmt.eprintfln(
			"norn: %s: %d of %d mutations could not be replayed",
			path,
			report.gaps,
			report.mutations,
		)
	}

	return EXIT_OK
}

command_inspect :: proc(arguments: []string) -> int {
	path := ""
	as_json := false

	for argument in arguments {
		switch argument {
		case "--json":
			as_json = true
		case:
			if strings.has_prefix(argument, "-") {
				fmt.eprintfln("norn: unknown option %q", argument)
				return EXIT_USAGE
			}
			if path != "" {
				fmt.eprintln("norn: inspect accepts one trace path")
				return EXIT_USAGE
			}
			path = argument
		}
	}

	if path == "" {
		fmt.eprintln("norn: inspect requires a trace path")
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

	if as_json {
		print_inspect_json(&trace)
	} else {
		print_inspect_text(path, &trace)
	}
	return EXIT_OK
}

// lookup resolves an interned string for display, returning a visible marker
// rather than empty text when the identifier does not resolve.
@(private)
lookup :: proc(trace: ^codec.Trace, id: model.String_Id) -> string {
	value, ok := model.string_get(&trace.strings, id)
	if !ok {
		return "<invalid string>"
	}
	return value
}

@(private)
print_inspect_text :: proc(path: string, trace: ^codec.Trace) {
	metadata := &trace.metadata

	fmt.printfln("trace:      %s", path)
	fmt.printfln("format:     %d.%d", trace.header.major, trace.header.minor)
	fmt.printfln(
		"importer:   %s %s",
		lookup(trace, metadata.importer_id),
		lookup(trace, metadata.importer_version),
	)
	fmt.printfln("repository: %s", lookup(trace, metadata.repository_name))
	fmt.printfln("baseline:   %s", baseline_name(metadata.baseline_kind))
	fmt.println()

	fmt.printfln("events:     %d", len(trace.events))
	fmt.printfln("entities:   %d", len(trace.entities))
	fmt.printfln("spans:      %d", len(trace.spans))
	fmt.printfln("edges:      %d", len(trace.edges))
	fmt.printfln("strings:    %d", model.string_table_count(&trace.strings))
	fmt.printfln("blobs:      %d", model.blob_table_count(&trace.blobs))
	fmt.printfln("chunks:     %d", len(trace.directory))
	fmt.println()

	// Event counts by kind give an immediate sense of what the session did.
	counts: map[model.Event_Kind]int
	defer delete(counts)
	for event in trace.events {
		counts[event.kind] += 1
	}
	if len(counts) > 0 {
		fmt.println("event kinds:")
		// Iterate the enum rather than the map: docs/10 forbids relying on map
		// iteration order, and unordered output would break diffing.
		for kind in model.Event_Kind {
			if count, present := counts[kind]; present {
				fmt.printfln("  %-20s %d", event_kind_name(kind), count)
			}
		}
		fmt.println()
	}

	// docs/01: import warnings remain visible as part of session metadata.
	warnings := codec.total_warnings(metadata)
	if warnings > 0 {
		fmt.printfln("import warnings: %d", warnings)
		for category in codec.Warning_Category {
			count := metadata.warnings[int(category)]
			if count > 0 {
				fmt.printfln("  %-20s %d", codec.warning_category_name(category), count)
			}
		}
		fmt.println()
	}

	redactions := codec.total_redactions(metadata)
	if redactions > 0 {
		fmt.printfln("redactions: %d", redactions)
		for category in codec.Redaction_Category {
			count := metadata.redactions[int(category)]
			if count > 0 {
				fmt.printfln("  %-20s %d", codec.redaction_category_name(category), count)
			}
		}
		fmt.println()
	}

	fmt.println("capabilities:")
	for capability in codec.Capability {
		if capability in metadata.capabilities {
			fmt.printfln("  %v", capability)
		}
	}
}

@(private)
print_inspect_json :: proc(trace: ^codec.Trace) {
	metadata := &trace.metadata

	fmt.println("{")
	// Braces are doubled: Odin's format verbs treat a bare `{` as a directive.
	fmt.printfln(
		`  "format": {{"major": %d, "minor": %d}},`,
		trace.header.major,
		trace.header.minor,
	)
	fmt.print(`  "importer": {"id": `)
	print_json_string(lookup(trace, metadata.importer_id))
	fmt.print(`, "version": `)
	print_json_string(lookup(trace, metadata.importer_version))
	fmt.println("},")

	fmt.print(`  "repository": {"name": `)
	print_json_string(lookup(trace, metadata.repository_name))
	fmt.printf(`, "baseline": "%s"`, baseline_name(metadata.baseline_kind))
	fmt.println("},")

	fmt.println(`  "counts": {`)
	fmt.printfln(`    "events": %d,`, len(trace.events))
	fmt.printfln(`    "entities": %d,`, len(trace.entities))
	fmt.printfln(`    "spans": %d,`, len(trace.spans))
	fmt.printfln(`    "edges": %d,`, len(trace.edges))
	fmt.printfln(`    "strings": %d,`, model.string_table_count(&trace.strings))
	fmt.printfln(`    "blobs": %d,`, model.blob_table_count(&trace.blobs))
	fmt.printfln(`    "chunks": %d`, len(trace.directory))
	fmt.println("  },")

	fmt.println(`  "warnings": {`)
	first := true
	for category in codec.Warning_Category {
		count := metadata.warnings[int(category)]
		if count == 0 {
			continue
		}
		if !first {
			fmt.println(",")
		}
		fmt.printf(`    "%s": %d`, codec.warning_category_name(category), count)
		first = false
	}
	if !first {
		fmt.println()
	}
	fmt.println("  },")

	fmt.println(`  "redactions": {`)
	first = true
	for category in codec.Redaction_Category {
		count := metadata.redactions[int(category)]
		if count == 0 {
			continue
		}
		if !first {
			fmt.println(",")
		}
		fmt.printf(`    "%s": %d`, codec.redaction_category_name(category), count)
		first = false
	}
	if !first {
		fmt.println()
	}
	fmt.println("  }")
	fmt.println("}")
}

// print_json_string writes a JSON string literal with the escaping required by
// RFC 8259. Trace content is untrusted, so it never reaches stdout unescaped;
// see docs/08 on provider records never becoming markup or format strings.
@(private)
print_json_string :: proc(value: string) {
	fmt.print(`"`)
	for index in 0 ..< len(value) {
		c := value[index]
		switch c {
		case '"':  fmt.print(`\"`)
		case '\\': fmt.print(`\\`)
		case '\n': fmt.print(`\n`)
		case '\r': fmt.print(`\r`)
		case '\t': fmt.print(`\t`)
		case '\b': fmt.print(`\b`)
		case '\f': fmt.print(`\f`)
		case:
			if c < 0x20 {
				fmt.printf(`\u%04x`, c)
			} else {
				// Bytes at or above 0x20 pass through unchanged, including
				// UTF-8 continuation bytes: JSON strings are UTF-8, so a
				// multi-byte sequence needs no escaping and must not be
				// re-encoded byte by byte.
				fmt.print(string(value[index:index + 1]))
			}
		}
	}
	fmt.print(`"`)
}

@(private)
baseline_name :: proc(kind: codec.Baseline_Kind) -> string {
	switch kind {
	case .None:                       return "none"
	case .Commit_Verified:            return "commit_verified"
	case .Working_Tree_Observational: return "working_tree_observational"
	}
	return "unknown"
}

@(private)
event_kind_name :: proc(kind: model.Event_Kind) -> string {
	return fmt.tprintf("%v", kind)
}
