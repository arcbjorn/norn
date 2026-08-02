package bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import "src:app"
import "src:core"
import "src:replay"
import "src:trace/model"
import "src:trace/codec"

// Replay seek benchmark.
//
// docs/00 budgets reconstructing any indexed text file at 100 ms p95, and
// docs/11 makes reference-fixture seek a Phase 2 exit criterion.
//
// Measured through app.replay_session_init and replay.seek — the same path the
// viewer takes. A benchmark that assembled the engine itself could easily be
// faster than the product and would prove nothing about it.
//
// Reports a distribution rather than one number: the claim is a p95, and a mean
// would hide the tail the budget is about.

// BUDGET_NS is the reconstruction budget from docs/00.
BUDGET_NS :: 100 * 1_000_000

main :: proc() {
	arguments := os.args[1:]
	if len(arguments) == 0 {
		fmt.eprintln("usage: bench <trace.norn>")
		os.exit(2)
	}

	path := arguments[0]
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("bench: cannot read %q: %v", path, read_err)
		os.exit(3)
	}
	defer delete(data)

	trace, open_err := codec.open_trace(data)
	if !core.ok(open_err) {
		fmt.eprintfln("bench: cannot open %q: %v", path, core.failure(open_err).message)
		os.exit(4)
	}
	defer codec.trace_destroy(&trace)

	fmt.printfln("trace:      %s", path)
	fmt.printfln("events:     %d", len(trace.events))
	fmt.printfln("mutations:  %d", len(trace.mutations))

	// Session setup is measured too: opening a trace and being able to seek is
	// one user-visible action, and a fast seek behind a slow build is not a
	// fast product.
	setup_start := time.tick_now()

	session: app.Replay_Session
	if !app.replay_session_init(&session, &trace) {
		fmt.eprintln("bench: the trace carries no file history to reconstruct")
		os.exit(5)
	}
	defer app.replay_session_destroy(&session)

	setup_ns := time.duration_nanoseconds(time.tick_since(setup_start))
	fmt.printfln("setup:      %.1f ms (baseline, timeline, snapshots)", f64(setup_ns) / 1e6)
	fmt.println()

	total := len(session.timeline.mutations)
	if total < 2 {
		fmt.eprintln("bench: too few mutations to measure")
		os.exit(5)
	}

	// Four seek patterns, because they exercise different code paths and only
	// the worst of them tells you whether the budget holds.
	measure_sequential_forward(&session, total)
	measure_sequential_backward(&session, total)
	measure_random(&session, total)
	measure_worst_case(&session, total)

	// Seeking only moves the path map. docs/00's budget is about reconstructing
	// a file, which is seek plus resolve — the latter fetches content and hashes
	// it to report verification status. Measuring seek alone would report a
	// number far under budget while saying nothing about the stated promise.
	fmt.println()
	measure_reconstruction(&session, &trace, total)
}

// measure_reconstruction times what docs/00 actually budgets: jump somewhere,
// then read a file's content back.
@(private)
measure_reconstruction :: proc(
	session: ^app.Replay_Session,
	trace: ^codec.Trace,
	total: int,
) {
	// Every path the session touched, so the measurement covers real subjects
	// rather than one convenient file.
	paths := make([dynamic]model.Entity_Id, 0, 32)
	defer delete(paths)
	for entity in trace.entities {
		if entity.kind == .Path {
			append(&paths, entity.id)
		}
	}
	if len(paths) == 0 {
		fmt.println("reconstruction: the trace names no paths")
		return
	}

	set := Sample_Set {
		name    = "seek + resolve",
		samples = make([dynamic]i64, 0, SAMPLE_LIMIT),
	}
	bytes := Sample_Set {
		name    = "resolve only",
		samples = make([dynamic]i64, 0, SAMPLE_LIMIT),
	}

	state := u64(0xD1B54A32D192ED03)
	samples := min(SAMPLE_LIMIT, total)
	resolved := 0
	total_bytes := 0

	for count in 0 ..< samples {
		state ~= state >> 12
		state ~= state << 25
		state ~= state >> 27
		mixed := state * 0x2545F4914F6CDD1D
		index := int(mixed % u64(total)) + 1
		path := paths[int((mixed >> 32) % u64(len(paths)))]

		start := time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, index)
		content := replay.resolve(&session.engine, path)
		elapsed := time.duration_nanoseconds(time.tick_since(start))
		record(&set, elapsed)

		// Resolve on its own, from an already-positioned engine: this is the
		// repeated cost when a user reads several files at one point in time.
		start = time.tick_now()
		again := replay.resolve(&session.engine, path)
		record(&bytes, time.duration_nanoseconds(time.tick_since(start)))

		if len(content.content) > 0 {
			resolved += 1
			total_bytes += len(content.content)
		}
		_ = again
		_ = count
	}

	report(&set)
	report(&bytes)

	// Stated so a reader can tell a fast measurement from an empty one. A
	// benchmark that resolved nothing would otherwise look excellent.
	fmt.printfln(
		"                       %d of %d resolves returned content, %d bytes total",
		resolved,
		samples,
		total_bytes,
	)
}

// Sample_Set accumulates timings for one access pattern.
Sample_Set :: struct {
	name:    string,
	samples: [dynamic]i64,
}

@(private)
record :: proc(set: ^Sample_Set, elapsed: i64) {
	append(&set.samples, elapsed)
}

// report prints the distribution and the budget verdict.
//
// p50, p95, and max: the budget is stated at p95, but a max far above it means
// some file somewhere takes that long, and a user who hits it does not care
// that the median was fine.
@(private)
report :: proc(set: ^Sample_Set) {
	defer delete(set.samples)

	if len(set.samples) == 0 {
		fmt.printfln("%-22s no samples", set.name)
		return
	}

	slice.sort(set.samples[:])

	p50 := set.samples[len(set.samples) * 50 / 100]
	p95 := set.samples[min(len(set.samples) * 95 / 100, len(set.samples) - 1)]
	worst := set.samples[len(set.samples) - 1]

	verdict := "within budget"
	if p95 > BUDGET_NS {
		verdict = "OVER BUDGET"
	}

	// Numbers are formatted to strings before being padded. Odin pads numeric
	// verbs with zeros rather than spaces — `%-6d` turns 2373 into "237300" and
	// `%8.3f` into "0000.041". docs/13 records this having produced garbage in
	// two earlier spikes; it is a trap for every aligned numeric column.
	fmt.printfln(
		"%-22s n=%-8s p50 %9s   p95 %9s   max %9s   %s",
		set.name,
		fmt.tprintf("%d", len(set.samples)),
		fmt.tprintf("%.3f ms", f64(p50) / 1e6),
		fmt.tprintf("%.3f ms", f64(p95) / 1e6),
		fmt.tprintf("%.3f ms", f64(worst) / 1e6),
		verdict,
	)
}

// SAMPLE_LIMIT bounds how many seeks each pattern performs.
//
// A benchmark that walked every mutation of the stress tier would take minutes
// and measure the same thing as a few thousand samples.
SAMPLE_LIMIT :: 2000

// measure_sequential_forward is the stepping case: each seek advances one
// mutation, replaying exactly one change. This is what holding an arrow key
// does, and it should be the cheapest pattern.
@(private)
measure_sequential_forward :: proc(session: ^app.Replay_Session, total: int) {
	set := Sample_Set {
		name    = "forward step",
		samples = make([dynamic]i64, 0, SAMPLE_LIMIT),
	}

	replay.engine_reset(&session.engine, &session.baseline)

	stride := max(1, total / SAMPLE_LIMIT)
	for index := 1; index <= total; index += stride {
		start := time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, index)
		record(&set, time.duration_nanoseconds(time.tick_since(start)))
	}

	report(&set)
}

// measure_sequential_backward is the expensive direction. Mutations are not
// invertible, so every backward seek restores a snapshot and replays forward
// from it — the case docs/06 introduced snapshots for.
@(private)
measure_sequential_backward :: proc(session: ^app.Replay_Session, total: int) {
	set := Sample_Set {
		name    = "backward step",
		samples = make([dynamic]i64, 0, SAMPLE_LIMIT),
	}

	replay.seek_to_index(&session.timeline, &session.engine, total)

	stride := max(1, total / SAMPLE_LIMIT)
	for index := total - 1; index >= 1; index -= stride {
		start := time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, index)
		record(&set, time.duration_nanoseconds(time.tick_since(start)))
	}

	report(&set)
}

// measure_random is timeline scrubbing: an arbitrary jump, which is what
// clicking around the timeline produces.
@(private)
measure_random :: proc(session: ^app.Replay_Session, total: int) {
	set := Sample_Set {
		name    = "random seek",
		samples = make([dynamic]i64, 0, SAMPLE_LIMIT),
	}

	// A fixed generator, so two runs of the benchmark measure the same seeks.
	// A random benchmark that varies its own workload cannot detect a
	// regression, because every difference is attributable to the input.
	state := u64(0x9E3779B97F4A7C15)
	samples := min(SAMPLE_LIMIT, total)

	for _ in 0 ..< samples {
		state ~= state >> 12
		state ~= state << 25
		state ~= state >> 27
		index := int((state * 0x2545F4914F6CDD1D) % u64(total)) + 1

		start := time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, index)
		record(&set, time.duration_nanoseconds(time.tick_since(start)))
	}

	report(&set)
}

// measure_worst_case is the pattern the budget has to survive: alternating
// between the two ends of the session, so no seek can continue from where the
// last one left off and every one pays a full snapshot restore plus replay.
@(private)
measure_worst_case :: proc(session: ^app.Replay_Session, total: int) {
	set := Sample_Set {
		name    = "end-to-end jump",
		samples = make([dynamic]i64, 0, 256),
	}

	samples := min(128, total)
	for index in 0 ..< samples {
		start := time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, total - index)
		record(&set, time.duration_nanoseconds(time.tick_since(start)))

		start = time.tick_now()
		replay.seek_to_index(&session.timeline, &session.engine, index + 1)
		record(&set, time.duration_nanoseconds(time.tick_since(start)))
	}

	report(&set)
}
