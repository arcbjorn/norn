package genfixture

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The NSL fixture generator.
//
// docs/09 defines four fixture tiers and requires that large fixtures be
// "generated deterministically when possible". Deterministic means a tier name
// alone reproduces the file byte for byte: no clock, no system entropy, no
// filesystem order. Only then can a golden test compare against a stored hash,
// and only then does a performance regression mean the code changed rather than
// the input.
//
// The generated content is invented. Per docs/05, fixtures must not contain
// real credentials, prompts, usernames, home paths, or source from other
// projects, so every string here is drawn from fixed vocabularies below.

VERSION :: "1"

// Tier sizes come from the table in docs/09.
Tier :: enum {
	Tiny,
	Representative,
	Reference,
	Stress,
}

tier_records :: proc(tier: Tier) -> int {
	// Records, not events: a command record expands to three canonical events,
	// so the record count is chosen to land the event count inside each tier's
	// band rather than to match it exactly.
	switch tier {
	case .Tiny:           return 40
	case .Representative: return 2_000
	case .Reference:      return 60_000
	case .Stress:         return 600_000
	}
	return 0
}

tier_name :: proc(tier: Tier) -> string {
	switch tier {
	case .Tiny:           return "tiny"
	case .Representative: return "representative"
	case .Reference:      return "reference"
	case .Stress:         return "stress"
	}
	return "unknown"
}

main :: proc() {
	arguments := os.args[1:]
	if len(arguments) == 0 {
		usage()
		os.exit(2)
	}

	tier: Tier
	found := false
	for candidate in Tier {
		if tier_name(candidate) == arguments[0] {
			tier = candidate
			found = true
			break
		}
	}
	if !found {
		fmt.eprintfln("genfixture: unknown tier %q", arguments[0])
		usage()
		os.exit(2)
	}

	destination := ""
	if len(arguments) > 1 {
		destination = arguments[1]
	}

	records := tier_records(tier)
	if len(arguments) > 2 {
		override, ok := strconv.parse_int(arguments[2])
		if !ok || override <= 0 {
			fmt.eprintln("genfixture: the record count must be a positive integer")
			os.exit(2)
		}
		records = override
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	generate(&builder, tier, records)

	text := strings.to_string(builder)
	if destination == "" {
		fmt.print(text)
		return
	}

	if err := os.write_entire_file(destination, transmute([]byte)text); err != nil {
		fmt.eprintfln("genfixture: cannot write %q: %v", destination, err)
		os.exit(3)
	}
	fmt.eprintfln("wrote %s (%d records, %d bytes)", destination, records, len(text))
}

usage :: proc() {
	fmt.eprintln("usage: genfixture <tiny|representative|reference|stress> [out.jsonl] [records]")
}

// Random is a seeded xorshift generator.
//
// Its own generator rather than core:math/rand, so a fixture stays identical
// across compiler and standard-library versions. A fixture that changed when
// the toolchain did would invalidate every stored hash for no reason.
Random :: struct {
	state: u64,
}

@(private)
next :: proc(random: ^Random) -> u64 {
	// xorshift64*, chosen for being short enough to reimplement anywhere and
	// good enough for choosing between vocabulary entries.
	x := random.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	random.state = x
	return x * 0x2545F4914F6CDD1D
}

@(private)
below :: proc(random: ^Random, limit: int) -> int {
	if limit <= 0 {
		return 0
	}
	return int(next(random) % u64(limit))
}

@(private)
pick :: proc(random: ^Random, options: []string) -> string {
	return options[below(random, len(options))]
}

// SEED fixes the sequence. One constant, so every tier of one build is
// reproducible and two builds agree.
SEED :: 0x6E6F726E5F303031

// START_TIME is a fixed instant: 2026-01-01T00:00:00Z in nanoseconds.
//
// Fixed rather than the current time, so the generated file does not change
// between runs. A fixture that embedded "now" could never be hash-compared.
START_TIME :: i64(1_767_225_600_000_000_000)

@(private)
PATHS := []string {
	"src/main.odin",
	"src/core/limits.odin",
	"src/trace/codec/reader.odin",
	"src/replay/engine.odin",
	"src/ui/timeline.odin",
	"src/analysis/scoring.odin",
	"tests/core/test_limits.odin",
	"docs/architecture.md",
}

@(private)
TOOLS := []string{"read_file", "edit_file", "search", "list_directory", "run_command"}

@(private)
COMMANDS := []string {
	"odin build src/main",
	"odin test tests/core",
	"odin test tests/replay",
	"odin check src",
}

@(private)
USER_TEXT := []string {
	"the timeline panel drops events when zoomed out",
	"make the failing replay test pass",
	"why does seek take so long on the large fixture",
	"add a bounds check to the chunk reader",
}

@(private)
AGENT_TEXT := []string {
	"looking at the reader first",
	"the bound was computed before the overflow check",
	"that test passes now; running the rest",
	"this needs a different approach",
}

@(private)
DIAGNOSTICS := []string {
	"undefined identifier",
	"cannot assign to a constant",
	"unused variable",
	"missing return statement",
}

@(private)
TESTS := []string {
	"reads_a_truncated_chunk",
	"rejects_an_absolute_path",
	"seeks_backward_to_a_snapshot",
	"applies_a_strict_patch",
}

// generate writes a complete NSL log.
//
// The shape is a plausible session rather than uniform noise: a user goal, then
// repeated cycles of reading, editing, running a command, and reacting to its
// result. Uniform records would make the timeline, the graph, and the analysis
// panels all degenerate, and a fixture that exercises none of them is not
// measuring what a real session costs.
generate :: proc(builder: ^strings.Builder, tier: Tier, records: int) {
	random := Random{state = SEED}
	time := START_TIME

	fmt.sbprintfln(
		builder,
		`{{"type":"session","nsl_version":1,"generator":"genfixture/%s","session":"%s","started_at":%d}}`,
		VERSION,
		tier_name(tier),
		time,
	)

	written := 0
	// Content is tracked per path so that a modify has a truthful `before`:
	// replay verifies each hash, so a chain whose before-content did not match
	// the previous after-content would produce gaps in every fixture.
	contents: map[string]string
	defer {
		for _, value in contents {
			delete(value)
		}
		delete(contents)
	}

	for written < records {
		// Each iteration is one agent turn: a goal, some work, a check.
		if written < records {
			write_message(builder, &random, &time, "user", pick(&random, USER_TEXT), true)
			written += 1
		}

		steps := 3 + below(&random, 6)
		for _ in 0 ..< steps {
			if written >= records {
				break
			}

			switch below(&random, 10) {
			case 0, 1, 2:
				written += write_read(builder, &random, &time)
			case 3, 4, 5:
				written += write_edit(builder, &random, &time, &contents)
			case 6, 7:
				written += write_command(builder, &random, &time)
			case 8:
				written += write_diagnostic(builder, &random, &time)
			case:
				written += write_test(builder, &random, &time)
			}
		}

		if written < records {
			write_message(builder, &random, &time, "assistant", pick(&random, AGENT_TEXT), false)
			written += 1
		}
	}
}

@(private)
advance :: proc(random: ^Random, time: ^i64) -> i64 {
	// Between 10ms and about 5s, so durations look like a session rather than a
	// metronome. Derived from the seeded generator, so it stays deterministic.
	time^ += i64(10_000_000 + below(random, 5_000_000_000))
	return time^
}

@(private)
write_message :: proc(
	builder: ^strings.Builder,
	random: ^Random,
	time: ^i64,
	role: string,
	text: string,
	goal: bool,
) {
	at := advance(random, time)
	if goal {
		fmt.sbprintfln(
			builder,
			`{{"type":"message","t":%d,"role":"%s","text":"%s","goal":true}}`,
			at,
			role,
			text,
		)
		return
	}
	fmt.sbprintfln(builder, `{{"type":"message","t":%d,"role":"%s","text":"%s"}}`, at, role, text)
}

@(private)
write_read :: proc(builder: ^strings.Builder, random: ^Random, time: ^i64) -> int {
	path := pick(random, PATHS)
	call := advance(random, time)
	id := next(random)

	fmt.sbprintfln(
		builder,
		`{{"type":"tool_call","t":%d,"id":"c%d","tool":"read_file","arguments":{{"path":"%s"}}}}`,
		call,
		id,
		path,
	)
	fmt.sbprintfln(
		builder,
		`{{"type":"file","t":%d,"op":"read","path":"%s"}}`,
		advance(random, time),
		path,
	)
	fmt.sbprintfln(
		builder,
		`{{"type":"tool_result","t":%d,"id":"c%d","status":"ok","content":"read %s"}}`,
		advance(random, time),
		id,
		path,
	)
	return 3
}

@(private)
write_edit :: proc(
	builder: ^strings.Builder,
	random: ^Random,
	time: ^i64,
	contents: ^map[string]string,
) -> int {
	path := pick(random, PATHS)
	id := next(random)

	previous, existed := contents[path]
	// A realistic source file, not a stub. docs/09 uses these fixtures for the
	// performance gates, and a 36-byte file measures nothing about
	// reconstructing, diffing, or hashing the sizes a real repository holds.
	after := generate_source(random, path)

	fmt.sbprintfln(
		builder,
		`{{"type":"tool_call","t":%d,"id":"c%d","tool":"edit_file","arguments":{{"path":"%s"}}}}`,
		advance(random, time),
		id,
		path,
	)

	if existed {
		// A modify states the content it replaced, so the chain verifies.
		fmt.sbprintfln(
			builder,
			`{{"type":"file","t":%d,"op":"modify","path":"%s","before":"%s","after":"%s"}}`,
			advance(random, time),
			path,
			previous,
			after,
		)
		delete(previous)
	} else {
		fmt.sbprintfln(
			builder,
			`{{"type":"file","t":%d,"op":"create","path":"%s","after":"%s"}}`,
			advance(random, time),
			path,
			after,
		)
	}
	contents[path] = after

	fmt.sbprintfln(
		builder,
		`{{"type":"tool_result","t":%d,"id":"c%d","status":"ok","content":"applied"}}`,
		advance(random, time),
		id,
	)
	return 3
}

// FILE_LINES bounds a generated file.
//
// Around 200-600 lines, which is the range the files in this repository
// actually occupy. Large enough that content handling is measured, small enough
// that the stress tier stays a file rather than a disk image.
FILE_MIN_LINES :: 200
FILE_LINE_SPAN :: 400

@(private)
LINE_FORMS := []string {
	"\\t\\tif index >= len(buffer) {",
	"\\t\\t\\treturn 0, false",
	"\\t\\t}",
	"\\tvalue := compute(index, offset)",
	"\\t// The bound is checked before the read, not after.",
	"\\tresult += u64(value) * scale",
	"\\tfor entry in entries {",
	"\\t\\ttotal += entry.size",
	"\\t}",
	"",
}

// generate_source builds a deterministic file body.
//
// Keyed off the path as well as the generator state, so two different files are
// not byte-identical — which would let content-addressed storage dedupe them
// and make the fixture measure one file instead of many.
@(private)
generate_source :: proc(random: ^Random, path: string) -> string {
	lines := FILE_MIN_LINES + below(random, FILE_LINE_SPAN)

	builder := strings.builder_make()
	fmt.sbprintf(&builder, "// %s\\n", path)
	fmt.sbprintf(&builder, "// revision %d\\n", next(random) % 1_000_000)
	strings.write_string(&builder, "package generated\\n\\n")

	for index in 0 ..< lines {
		form := LINE_FORMS[index %% len(LINE_FORMS)]
		if form == "" {
			strings.write_string(&builder, "\\n")
			continue
		}
		fmt.sbprintf(&builder, "%s\\n", form)
	}

	return strings.to_string(builder)
}

@(private)
write_command :: proc(builder: ^strings.Builder, random: ^Random, time: ^i64) -> int {
	command := pick(random, COMMANDS)
	// Mostly passing, so a failure is a signal rather than the norm — which is
	// what the analysis panels need in order to have anything to rank.
	failed := below(random, 4) == 0
	exit := 1 if failed else 0
	output := "1 error" if failed else "ok"

	fmt.sbprintfln(
		builder,
		`{{"type":"command","t":%d,"command":"%s","exit":%d,"output":"%s","duration_ns":%d}}`,
		advance(random, time),
		command,
		exit,
		output,
		i64(100_000_000 + below(random, 3_000_000_000)),
	)
	return 1
}

@(private)
write_diagnostic :: proc(builder: ^strings.Builder, random: ^Random, time: ^i64) -> int {
	fmt.sbprintfln(
		builder,
		`{{"type":"diagnostic","t":%d,"severity":"error","path":"%s","line":%d,"column":%d,"code":"E%d","message":"%s"}}`,
		advance(random, time),
		pick(random, PATHS),
		1 + below(random, 400),
		1 + below(random, 60),
		1000 + below(random, 100),
		pick(random, DIAGNOSTICS),
	)
	return 1
}

@(private)
write_test :: proc(builder: ^strings.Builder, random: ^Random, time: ^i64) -> int {
	failed := below(random, 5) == 0
	status := "fail" if failed else "pass"
	name := pick(random, TESTS)

	if failed {
		fmt.sbprintfln(
			builder,
			`{{"type":"test","t":%d,"name":"%s","suite":"generated","status":"fail","message":"expected 1, got 0","path":"%s","line":%d}}`,
			advance(random, time),
			name,
			pick(random, PATHS),
			1 + below(random, 200),
		)
		return 1
	}

	fmt.sbprintfln(
		builder,
		`{{"type":"test","t":%d,"name":"%s","suite":"generated","status":"pass"}}`,
		advance(random, time),
		name,
	)
	return 1
}
