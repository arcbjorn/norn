package test_replay

import "core:fmt"
import "core:math/rand"
import "core:testing"

import "src:replay"
import "src:trace/model"

// Seeking, snapshots, and range comparison.
//
// docs/09 requires: sequential replay equals replay from every valid snapshot,
// and seeking forward and backward yields identical state. These are the
// properties that make a scrubbing timeline trustworthy — a user dragging the
// playhead must see the same repository whichever direction they arrived from.

// state_digest summarizes an engine's whole repository state so two states can
// be compared with one assertion.
//
// It folds in the path, existence, status, and content digest of every path,
// order-independently, so it detects a difference anywhere in the state
// without depending on map iteration order.
@(private)
state_digest :: proc(engine: ^replay.Engine, paths: []model.Entity_Id) -> string {
	builder := make([dynamic]u8, 0, 256, context.temp_allocator)
	for path in paths {
		resolved := replay.resolve(engine, path)
		line := fmt.tprintf(
			"%d:%s:%s|",
			u64(path),
			replay.resolved_status_name(resolved.status),
			string(resolved.content),
		)
		append(&builder, ..transmute([]byte)line)
	}
	return string(builder[:])
}

// build_varied_session creates a session exercising every mutation form,
// including one that fails, so seeking is tested across gaps too.
@(private)
build_varied_session :: proc(session: ^Session, count: int) {
	session_init(session)

	baseline_file(session, PATH_A, "a0\n")
	baseline_file(session, PATH_B, "b0\n")
	baseline_absent(session, PATH_C)

	for step in 0 ..< count {
		switch step % 6 {
		case 0:
			before := fmt.aprintf("a%d\n", step / 6)
			after := fmt.aprintf("a%d\n", step / 6 + 1)
			write_full(session, PATH_A, before, after)
			delete(before)
			delete(after)
		case 1:
			// A patch against B's current content.
			text := fmt.aprintf("@@ -1,1 +1,1 @@\n-b%d\n+b%d\n", step / 6, step / 6 + 1)
			expected := fmt.aprintf("b%d\n", step / 6 + 1)
			write_patch(session, PATH_B, text, expected)
			delete(text)
			delete(expected)
		case 2:
			content := fmt.aprintf("c%d\n", step)
			write_full(session, PATH_C, "", content, .Create)
			delete(content)
		case 3:
			delete_file(session, PATH_C)
		case 4:
			// A patch that cannot apply, producing a gap on A.
			write_patch(session, PATH_A, "@@ -1,1 +1,1 @@\n-nomatch\n+broken\n", "")
		case 5:
			// Full content recovers A from the gap the previous step made.
			content := fmt.aprintf("a%d\n", step / 6 + 1)
			write_full(session, PATH_A, "", content, .Modify)
			delete(content)
		}
	}
}

@(test)
sequential_replay_equals_replay_from_every_snapshot :: proc(t: ^testing.T) {
	// docs/09 property: sequential replay equals replay from every valid
	// snapshot. This is what makes snapshots a safe optimization rather than a
	// second, subtly different implementation of history.
	session: Session
	build_varied_session(&session, 40)
	defer session_destroy(&session)

	paths := []model.Entity_Id{PATH_A, PATH_B, PATH_C}

	// Reference: walk the whole history one mutation at a time, recording the
	// state after each step.
	reference: replay.Engine
	reference_timeline: replay.Timeline
	start(&session, &reference, &reference_timeline)
	defer replay.engine_destroy(&reference)
	defer replay.timeline_destroy(&reference_timeline)

	expected := make([dynamic]string, 0, len(session.mutations) + 1)
	defer delete(expected)
	append(&expected, state_digest(&reference, paths))
	for mutation in session.mutations {
		replay.apply_mutation(&reference, mutation)
		append(&expected, state_digest(&reference, paths))
	}

	// Now build snapshots and seek to each index, which restores the nearest
	// snapshot and replays forward from there.
	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	replay.timeline_build_snapshots(&timeline, &engine)
	testing.expect(
		t,
		len(timeline.snapshots) >= 1,
		"the baseline must always be snapshotted",
	)

	for index in 0 ..= len(session.mutations) {
		replay.seek_to_index(&timeline, &engine, index)
		actual := state_digest(&engine, paths)
		testing.expectf(
			t,
			actual == expected[index],
			"state after %d mutations differed: snapshot path gave %q, sequential gave %q",
			index,
			actual,
			expected[index],
		)
	}
}

@(test)
forward_and_backward_seek_agree :: proc(t: ^testing.T) {
	// docs/09 property: seeking forward and backward yields identical state.
	// Backward seeking restarts from a snapshot because mutations are not
	// invertible, so this checks that reconstruction agrees with the walk that
	// originally produced the state.
	session: Session
	build_varied_session(&session, 30)
	defer session_destroy(&session)

	paths := []model.Entity_Id{PATH_A, PATH_B, PATH_C}

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	// Record every state on the way forward.
	forward := make([dynamic]string, 0, len(session.mutations) + 1)
	defer delete(forward)
	for index in 0 ..= len(session.mutations) {
		replay.seek_to_index(&timeline, &engine, index)
		append(&forward, state_digest(&engine, paths))
	}

	// Revisit them in reverse; each must match what the forward pass saw.
	for index := len(session.mutations); index >= 0; index -= 1 {
		replay.seek_to_index(&timeline, &engine, index)
		actual := state_digest(&engine, paths)
		testing.expectf(
			t,
			actual == forward[index],
			"backward seek to %d gave %q, forward gave %q",
			index,
			actual,
			forward[index],
		)
	}
}

@(test)
random_seek_order_is_consistent :: proc(t: ^testing.T) {
	// Scrubbing a timeline produces arbitrary seek orders, not just monotone
	// ones. Jumping around must never leave the engine in a state that depends
	// on how it got there.
	session: Session
	build_varied_session(&session, 25)
	defer session_destroy(&session)

	paths := []model.Entity_Id{PATH_A, PATH_B, PATH_C}

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	expected := make([dynamic]string, 0, len(session.mutations) + 1)
	defer delete(expected)
	for index in 0 ..= len(session.mutations) {
		replay.seek_to_index(&timeline, &engine, index)
		append(&expected, state_digest(&engine, paths))
	}

	generator := rand.create(0x5EED)
	context.random_generator = rand.default_random_generator(&generator)

	for _ in 0 ..< 200 {
		index := rand.int_max(len(session.mutations) + 1)
		replay.seek_to_index(&timeline, &engine, index)
		actual := state_digest(&engine, paths)
		testing.expectf(
			t,
			actual == expected[index],
			"random seek to %d gave %q, expected %q",
			index,
			actual,
			expected[index],
		)
	}
}

@(test)
snapshots_are_taken_at_the_documented_interval :: proc(t: ^testing.T) {
	// docs/06: always snapshot the verified baseline, then after every 256
	// replayable mutations.
	session: Session
	build_varied_session(&session, replay.SNAPSHOT_INTERVAL * 2 + 10)
	defer session_destroy(&session)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	replay.timeline_build_snapshots(&timeline, &engine)

	// Baseline plus one per completed interval.
	expected := 1 + len(session.mutations) / replay.SNAPSHOT_INTERVAL
	testing.expect_value(t, len(timeline.snapshots), expected)
	testing.expect_value(t, timeline.snapshots[0].index, 0)
}

@(test)
seeking_with_no_snapshots_still_works :: proc(t: ^testing.T) {
	// Snapshots are derived and may be absent or discarded, per docs/04. Seek
	// must fall back to replaying from the baseline rather than failing.
	session: Session
	build_varied_session(&session, 12)
	defer session_destroy(&session)

	paths := []model.Entity_Id{PATH_A, PATH_B, PATH_C}

	reference: replay.Engine
	reference_timeline: replay.Timeline
	start(&session, &reference, &reference_timeline)
	defer replay.engine_destroy(&reference)
	defer replay.timeline_destroy(&reference_timeline)
	run_all(&session, &reference)
	expected := state_digest(&reference, paths)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	// No timeline_build_snapshots call: the timeline has none.
	replay.seek_to_index(&timeline, &engine, len(session.mutations))
	testing.expect_value(t, state_digest(&engine, paths), expected)
}

@(test)
seeking_to_the_start_returns_the_baseline :: proc(t: ^testing.T) {
	session: Session
	build_varied_session(&session, 15)
	defer session_destroy(&session)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	replay.seek_to_index(&timeline, &engine, len(session.mutations))
	replay.seek_to_index(&timeline, &engine, 0)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(resolved.content), "a0\n")
}

// ---------------------------------------------------------------------------
// Range comparison
// ---------------------------------------------------------------------------

@(test)
comparison_reports_created_modified_and_deleted :: proc(t: ^testing.T) {
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "a\n")
	baseline_file(&session, PATH_B, "b\n")
	baseline_absent(&session, PATH_C)

	write_full(&session, PATH_A, "a\n", "A\n") // modified
	delete_file(&session, PATH_B) // deleted
	write_full(&session, PATH_C, "", "c\n", .Create) // created

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	last := session.sequences[len(session.sequences) - 1]
	comparison := replay.compare_range(&timeline, &engine, 0, last)
	defer replay.comparison_destroy(&comparison)

	kinds := make(map[model.Entity_Id]replay.Change_Kind)
	defer delete(kinds)
	for change in comparison.changes {
		kinds[change.path] = change.kind
	}

	testing.expect_value(t, kinds[PATH_A], replay.Change_Kind.Modified)
	testing.expect_value(t, kinds[PATH_B], replay.Change_Kind.Deleted)
	testing.expect_value(t, kinds[PATH_C], replay.Change_Kind.Created)
}

@(test)
comparison_omits_paths_restored_to_identical_content :: proc(t: ^testing.T) {
	// A comparison describes the difference between two moments, not the route
	// between them. The timeline already shows the route.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "original\n")
	write_full(&session, PATH_A, "original\n", "changed\n")
	write_full(&session, PATH_A, "changed\n", "original\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	last := session.sequences[len(session.sequences) - 1]
	comparison := replay.compare_range(&timeline, &engine, 0, last)
	defer replay.comparison_destroy(&comparison)

	testing.expect_value(t, len(comparison.changes), 0)
}

@(test)
comparison_flags_gaps :: proc(t: ^testing.T) {
	// docs/06: replay gaps affecting the comparison must be reported with it,
	// so a diff built over unknown content is never shown as complete.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "a\n")
	write_patch(&session, PATH_A, "@@ -1,1 +1,1 @@\n-nomatch\n+x\n", "")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	last := session.sequences[len(session.sequences) - 1]
	comparison := replay.compare_range(&timeline, &engine, 0, last)
	defer replay.comparison_destroy(&comparison)

	testing.expect(t, comparison.gap_count > 0, "a gap in the range must be reported")
	found := false
	for change in comparison.changes {
		if change.path == PATH_A {
			found = true
			testing.expect(t, change.affected_by_gap)
		}
	}
	testing.expect(t, found, "the damaged path must appear in the comparison")
}

@(test)
comparison_is_symmetric_in_its_endpoints :: proc(t: ^testing.T) {
	// Selecting a range backwards is an ordinary thing to do with a mouse.
	session: Session
	build_varied_session(&session, 12)
	defer session_destroy(&session)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)
	replay.timeline_build_snapshots(&timeline, &engine)

	last := session.sequences[len(session.sequences) - 1]

	forward := replay.compare_range(&timeline, &engine, 0, last)
	defer replay.comparison_destroy(&forward)
	backward := replay.compare_range(&timeline, &engine, last, 0)
	defer replay.comparison_destroy(&backward)

	testing.expect_value(t, len(forward.changes), len(backward.changes))
	testing.expect_value(t, forward.from, backward.from)
	testing.expect_value(t, forward.to, backward.to)
}
