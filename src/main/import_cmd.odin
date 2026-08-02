package main

import "core:fmt"
import "core:os"
import "core:strings"

import "src:core"
import api "src:importers/api"

// `norn import`.
//
// docs/10 fixes the invocation:
//
//   norn import <source> --repo <path> [--format codex] [--out file.norn]
//
// This is the one command that runs another program: docs/05 permits reading
// baseline content with `git show` under a fixed argument vector. Everything
// else about the source is data. In particular the source log is never
// executed, and no command found inside it is ever run.

command_import :: proc(arguments: []string) -> int {
	source_path := ""
	repository_path := ""
	format := ""
	destination := ""
	retain_raw := false
	dry_run := false

	index := 0
	for index < len(arguments) {
		argument := arguments[index]
		switch argument {
		case "--repo":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --repo requires a path")
				return EXIT_USAGE
			}
			repository_path = arguments[index]
		case "--format":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --format requires a value")
				return EXIT_USAGE
			}
			format = arguments[index]
		case "--out":
			index += 1
			if index >= len(arguments) {
				fmt.eprintln("norn: --out requires a path")
				return EXIT_USAGE
			}
			destination = arguments[index]
		case "--retain-raw-records":
			// docs/10 keeps raw provider records opt-in: they help adapter
			// debugging but substantially increase privacy exposure.
			retain_raw = true
		case "--dry-run":
			// docs/01: import reports detected metadata and unsupported record
			// types before writing output. This stops after that report.
			dry_run = true
		case:
			if strings.has_prefix(argument, "-") {
				fmt.eprintfln("norn: unknown option %q", argument)
				return EXIT_USAGE
			}
			if source_path != "" {
				fmt.eprintln("norn: import accepts one source path")
				return EXIT_USAGE
			}
			source_path = argument
		}
		index += 1
	}

	if source_path == "" {
		fmt.eprintln("norn: import requires a source path")
		return EXIT_USAGE
	}
	if repository_path == "" && !dry_run {
		// The repository is what makes mutations replayable, so importing
		// without one silently produces a trace that cannot be stepped.
		fmt.eprintln("norn: import requires --repo <path>")
		return EXIT_USAGE
	}

	source, read_err := os.read_entire_file_from_path(source_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("norn: cannot read %q: %v", source_path, read_err)
		return EXIT_INPUT_ERROR
	}
	defer delete(source)

	registry: api.Registry
	api.registry_init(&registry)
	defer api.registry_destroy(&registry)
	register_importers(&registry)

	importer, chosen, code := select_importer(&registry, source, source_path, format)
	if !chosen {
		return code
	}

	if dry_run {
		return report_inspection(importer, source, source_path)
	}

	repository, repository_err := api.inspect_repository(repository_path)
	if !core.ok(repository_err) {
		report_error(repository_path, repository_err)
		return exit_code_for(repository_err)
	}
	defer api.repository_destroy(&repository)

	if !repository.is_git {
		// docs/05 allows an import with no version control; the trace records
		// that rather than the importer refusing. Saying so matters because it
		// determines how much of the session can be replayed.
		fmt.eprintfln(
			"norn: %s is not a git repository; mutations will not be verifiable",
			repository_path,
		)
	}

	out := destination
	if out == "" {
		out = default_destination(source_path)
	}

	options := api.Options {
		retain_raw_records = retain_raw,
		repository_root    = repository.root,
		home_prefix        = home_directory(),
	}

	outcome, import_err := api.import_source(
		importer,
		source,
		out,
		api.to_identity(&repository),
		options,
	)
	if !core.ok(import_err) {
		report_error(source_path, import_err)
		// docs/11: import never leaves a complete-looking destination after a
		// failure. The writer removes its temporary; nothing to clean up here.
		return exit_code_for(import_err)
	}

	report := api.format_report(&outcome, context.allocator)
	defer delete(report)

	fmt.printfln("wrote %s", outcome.destination)
	fmt.println()
	fmt.print(report)
	return EXIT_OK
}

// select_importer applies the auto-detection rule from docs/05.
//
// "Auto-detection proceeds only when one adapter has high confidence and no
// adapter has comparable confidence. Otherwise the user chooses explicitly."
// Ambiguity is a usage error rather than a guess: importing with the wrong
// adapter produces a plausible-looking trace of the wrong session.
@(private)
select_importer :: proc(
	registry: ^api.Registry,
	source: []byte,
	source_path: string,
	format: string,
) -> (
	importer: api.Importer,
	chosen: bool,
	code: int,
) {
	if len(registry.adapters) == 0 {
		// Honest failure. A build with no adapters cannot import anything, and
		// saying so beats reporting an unrecognized format.
		fmt.eprintln("norn: this build has no importers")
		return {}, false, EXIT_UNSUPPORTED
	}

	if format != "" {
		found: bool
		importer, found = api.find(registry, format)
		if !found {
			fmt.eprintfln("norn: unknown format %q", format)
			print_available_formats(registry)
			return {}, false, EXIT_USAGE
		}
		return importer, true, EXIT_OK
	}

	results := api.detect_all(registry, source, source_path, context.allocator)
	defer delete(results)

	selected, ok := api.choose_adapter(results[:])
	if !ok {
		if len(results) == 0 {
			fmt.eprintfln("norn: no importer recognizes %q", source_path)
		} else {
			// Report what was considered, so --format is an informed choice
			// rather than a guess of the identifier's spelling.
			fmt.eprintfln("norn: %q is ambiguous; choose with --format", source_path)
			for result in results {
				detection := result.detection
				fmt.eprintfln(
					"  %-12s %v",
					result.importer.id,
					detection.confidence,
				)
				for reason in api.reasons(&detection) {
					fmt.eprintfln("    %s", reason)
				}
			}
		}
		return {}, false, EXIT_UNSUPPORTED
	}

	return selected, true, EXIT_OK
}

@(private)
print_available_formats :: proc(registry: ^api.Registry) {
	fmt.eprintln("available formats:")
	for adapter in registry.adapters {
		fmt.eprintfln("  %s %s", adapter.id, adapter.version)
	}
}

// report_inspection prints what the source contains without writing anything.
//
// docs/01: import "shows the detected session metadata, and reports any
// unsupported record types before writing output." A user should learn a trace
// is half unsupported before waiting for it to be written.
@(private)
report_inspection :: proc(importer: api.Importer, source: []byte, source_path: string) -> int {
	metadata, err := api.inspect_source(importer, source, context.allocator)
	if !core.ok(err) {
		report_error(source_path, err)
		return exit_code_for(err)
	}
	defer api.source_metadata_destroy(&metadata)

	fmt.printfln("source:    %s", source_path)
	fmt.printfln("importer:  %s %s", importer.id, importer.version)
	fmt.printfln("variant:   %s", metadata.variant)
	fmt.printfln("records:   %d", metadata.record_count)
	fmt.printfln("size:      %d bytes", metadata.size_bytes)

	if len(metadata.unsupported_types) > 0 {
		// Named individually: a count alone does not tell a user whether the
		// unsupported records are the ones they cared about.
		fmt.println()
		fmt.printfln("unsupported record types: %d", len(metadata.unsupported_types))
		for name in metadata.unsupported_types {
			fmt.printfln("  %s", name)
		}
	}

	fmt.println()
	fmt.println("expected capabilities:")
	expected := metadata.expected
	fmt.printfln("  timestamps        %v", expected.timestamps)
	fmt.printfln("  conversation      %v", expected.conversation)
	fmt.printfln("  tool calls        %v", expected.tool_calls)
	fmt.printfln("  file mutations    %v", expected.file_mutations)
	fmt.printfln("  command output    %v", expected.command_output)
	fmt.printfln("  structured tests  %v", expected.structured_tests)

	return EXIT_OK
}

// default_destination derives an output path from the source name.
//
// Beside the source rather than in the working directory, so a shell loop over
// several logs does not collide on one output name.
@(private)
default_destination :: proc(source_path: string) -> string {
	trimmed := source_path
	for suffix in ([]string{".jsonl", ".json", ".log", ".txt"}) {
		if strings.has_suffix(trimmed, suffix) {
			trimmed = trimmed[:len(trimmed) - len(suffix)]
			break
		}
	}
	return strings.concatenate({trimmed, ".norn"}, context.allocator)
}

// home_directory returns the current home for redaction.
//
// docs/08: home-directory prefixes are replaced with a stable placeholder. An
// empty result simply means that rule does not fire.
@(private)
home_directory :: proc() -> string {
	value, found := os.lookup_env("HOME", context.allocator)
	if !found {
		return ""
	}
	return value
}

// register_importers installs the adapters this build carries.
//
// docs/05 locks the first adapter's schema with fixtures, so an adapter appears
// here only once its fixtures exist. An empty registry produces an honest
// "no importers" failure rather than a wrong guess.
@(private)
register_importers :: proc(registry: ^api.Registry) {
}
