package main

import "core:fmt"
import "core:os"

// Norn command-line entry point.
//
// docs/10-development.md fixes the product CLI surface and requires explicit
// exit codes with machine-readable output on stdout kept separate from
// diagnostics on stderr. Every command here writes results to stdout and
// every warning or error to stderr, so `norn inspect --json` can be piped
// without a filter.

// Exit codes are part of the CLI contract. Scripts branch on these, so values
// are appended rather than renumbered.
EXIT_OK             :: 0
EXIT_USAGE          :: 2 // Malformed invocation.
EXIT_INPUT_ERROR    :: 3 // The named input could not be read.
EXIT_INVALID_TRACE  :: 4 // The trace failed validation.
EXIT_UNSUPPORTED    :: 5 // A recognized but unsupported format or feature.
EXIT_INTERNAL       :: 70

VERSION :: "0.1.0-dev"

main :: proc() {
	arguments := os.args[1:]
	if len(arguments) == 0 {
		print_usage(false)
		os.exit(EXIT_OK)
	}

	command := arguments[0]
	rest := arguments[1:]

	switch command {
	case "import":
		os.exit(command_import(rest))
	case "inspect":
		os.exit(command_inspect(rest))
	case "validate":
		os.exit(command_validate(rest))
	case "open":
		os.exit(command_open(rest))
	case "explain":
		os.exit(command_explain(rest))
	case "export":
		os.exit(command_export(rest))
	case "version", "--version", "-v":
		fmt.println(VERSION)
		os.exit(EXIT_OK)
	case "help", "--help", "-h":
		print_usage(false)
		os.exit(EXIT_OK)
	case:
		fmt.eprintfln("norn: unknown command %q", command)
		print_usage(true)
		os.exit(EXIT_USAGE)
	}
}

print_usage :: proc(to_stderr: bool) {
	usage := `Norn - time-travel debugger for coding-agent sessions

Usage:
  norn open <trace.norn>
  norn import <source> --repo <path> [--format <id>] [--out file.norn]
  norn inspect <trace.norn> [--json]
  norn validate <trace.norn> [--mode quick|full|replay]
  norn explain <trace.norn> --event <id>
  norn explain <trace.norn> --list
  norn export <trace.norn> --out <dir> [--range start:end] [--event <id>]
  norn version

Export includes file paths, diffs, command lines, and evidence by default.
Prompt text and command output are excluded unless --include-messages or
--include-output is given.

Import reads a source log and writes a .norn trace. It never executes the
source or anything named inside it. Use --dry-run to report what a source
contains without writing output.

Exit codes:
  0  success
  2  usage error
  3  input could not be read
  4  trace failed validation
  5  unsupported format or feature`

	// Usage accompanying a usage error belongs on stderr so that stdout stays
	// reserved for machine-readable output, per docs/10.
	if to_stderr {
		fmt.eprintln(usage)
	} else {
		fmt.println(usage)
	}
}
