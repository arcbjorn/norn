package test_codec

import "core:fmt"
import "core:os"
import "core:testing"

import "src:core"
import "src:trace/codec"

// File-level write behavior.
//
// docs/04-trace-format.md requires import to write `<destination>.tmp` and
// atomically rename only after reopening and validating the finished file, and
// docs/11 makes "import never writes a complete-looking destination after
// failure" an exit criterion for phase one.

@(private)
temporary_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/norn-test-%s.norn", os.temp_directory(context.temp_allocator), name)
}

@(test)
write_trace_publishes_a_validating_file :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	path := temporary_path("publish")
	defer os.remove(path)

	err := codec.write_trace(path, &fixture.content)
	testing.expectf(t, core.ok(err), "write failed: %s", core.error_message(err))

	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, read_err == nil, "the published trace must be readable")
	defer delete(data)

	testing.expect(t, core.ok(codec.validate_full(data)), "the published trace must validate")
}

@(test)
write_trace_leaves_no_temporary_file :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	path := temporary_path("no-temp")
	defer os.remove(path)

	err := codec.write_trace(path, &fixture.content)
	testing.expect(t, core.ok(err))

	// A leftover .tmp would be mistaken for an interrupted import.
	temporary := fmt.tprintf("%s.tmp", path)
	testing.expect(t, !os.exists(temporary), "the temporary file must not survive a success")
}

@(test)
published_trace_reopens_with_identical_content :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	path := temporary_path("reopen")
	defer os.remove(path)

	testing.expect(t, core.ok(codec.write_trace(path, &fixture.content)))

	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(data)

	trace, err := codec.open_trace(data)
	testing.expectf(t, core.ok(err), "reopen failed: %s", core.error_message(err))
	defer codec.trace_destroy(&trace)

	// docs/11: the representative trace can be inspected without the source.
	testing.expect_value(t, len(trace.events), len(fixture.events))
	testing.expect_value(t, len(trace.edges), len(fixture.edges))
	testing.expect_value(t, trace.metadata.canonical_event_count, u64(len(fixture.events)))
}
