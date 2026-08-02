package main

import "core:fmt"
import "core:os"
import "core:strings"

import "src:app"
import "src:core"
import "src:trace/codec"

// `norn open` — the desktop application.
//
// docs/10 lists this as the primary entry point. It validates the trace before
// opening a window, because a malformed trace should produce a clear message
// on the terminal rather than an empty window the user has to close.

command_open :: proc(arguments: []string) -> int {
	path := ""

	for argument in arguments {
		if strings.has_prefix(argument, "-") {
			fmt.eprintfln("norn: unknown option %q", argument)
			return EXIT_USAGE
		}
		if path != "" {
			fmt.eprintln("norn: open accepts one trace path")
			return EXIT_USAGE
		}
		path = argument
	}

	if path == "" {
		fmt.eprintln("norn: open requires a trace path")
		return EXIT_USAGE
	}

	data, code := read_trace_file(path)
	if code != EXIT_OK {
		return code
	}
	defer delete(data)

	// Structural validation first: a window is a poor place to report that a
	// file is not a trace.
	if err := codec.validate_quick(data); !core.ok(err) {
		report_error(path, err)
		return exit_code_for(err)
	}

	trace, err := codec.open_trace(data)
	if !core.ok(err) {
		report_error(path, err)
		return exit_code_for(err)
	}
	defer codec.trace_destroy(&trace)

	title := strings.clone_to_cstring(fmt.tprintf("Norn — %s", path), context.temp_allocator)
	defer delete(title, context.temp_allocator)

	window: app.Window
	if window_err := app.open(&window, title); !core.ok(window_err) {
		report_error(path, window_err)
		return exit_code_for(window_err)
	}
	defer app.close(&window)

	state: app.State
	app.state_init(&state, &trace, window.width)

	app.run(&window, &state, &trace)
	return EXIT_OK
}
