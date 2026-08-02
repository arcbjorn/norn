package app

import "src:replay"
import "src:trace/codec"
import "src:trace/model"

// Replay driven from the playhead.
//
// docs/01-user-experience.md: "dragging the playhead updates the virtual
// repository and all derived panels." This is the connection that makes that
// true — it owns a replay engine for the open trace and keeps it seeked to
// whatever moment the selection names.
//
// The engine is expensive to reset and cheap to advance, so it is created once
// per trace and seeked rather than rebuilt per frame. docs/06's snapshot
// policy exists precisely so that seeking is affordable.

// Replay_Session holds the replay state for one open trace.
Replay_Session :: struct {
	engine:   replay.Engine,
	timeline: replay.Timeline,
	baseline: replay.Baseline,

	// Mutation sequences, parallel to the trace's mutation slice. The timeline
	// needs sequences and mutations reference events, so the mapping is
	// resolved once here rather than per seek.
	sequences: [dynamic]model.Sequence,

	// The sequence the engine currently reflects, so a frame that did not move
	// the playhead does not re-seek.
	position: model.Sequence,

	// False when the trace records no mutations, in which case there is
	// nothing to replay and the panels should say so rather than showing an
	// empty repository as though it were a reconstructed one.
	usable: bool,
}

// replay_session_init prepares replay for a trace.
//
// Returns false when the trace carries nothing to reconstruct. That is a
// legitimate state — a session that only ran commands has no file history —
// and the caller reports it rather than treating it as an error.
replay_session_init :: proc(
	session: ^Replay_Session,
	trace: ^codec.Trace,
	allocator := context.allocator,
) -> bool {
	session.sequences = make([dynamic]model.Sequence, 0, len(trace.mutations), allocator)

	for mutation in trace.mutations {
		index := int(mutation.event_id) - 1
		if index < 0 || index >= len(trace.events) {
			// A mutation naming a missing event cannot be placed in time.
			// Validation rejects such a trace, so reaching here means the
			// caller skipped validation; dropping it is safer than guessing.
			continue
		}
		append(&session.sequences, trace.events[index].sequence)
	}

	if len(session.sequences) != len(trace.mutations) || len(trace.mutations) == 0 {
		session.usable = false
		return false
	}

	replay.baseline_init(
		&session.baseline,
		baseline_kind_for(trace.metadata.baseline_kind),
		allocator,
	)

	// The baseline manifest the importer captured. A trace without one replays
	// from nothing, which makes a patch against a pre-existing file a
	// missing-baseline gap — still the honest result, just a weaker one.
	for entry in trace.baseline {
		append(&session.baseline.entries, entry)
	}

	source := replay.Content_Source {
		user_data = trace,
		fetch = proc(user_data: rawptr, id: model.Blob_Id) -> ([]byte, bool) {
			trace := cast(^codec.Trace)user_data
			content, err := codec.trace_blob_content(trace, id)
			return content, err == nil
		},
	}

	replay.engine_init(&session.engine, source, allocator)
	replay.timeline_init(
		&session.timeline,
		trace.mutations[:],
		session.sequences[:],
		&session.baseline,
		allocator,
	)
	replay.engine_reset(&session.engine, &session.baseline)

	// Snapshots are built once so seeking backward is a restore plus a short
	// forward replay rather than a walk from the session start.
	replay.timeline_build_snapshots(&session.timeline, &session.engine, allocator)
	replay.engine_reset(&session.engine, &session.baseline)

	session.position = 0
	session.usable = true
	return true
}

replay_session_destroy :: proc(session: ^Replay_Session) {
	replay.timeline_destroy(&session.timeline)
	replay.engine_destroy(&session.engine)
	replay.baseline_destroy(&session.baseline)
	delete(session.sequences)
	session^ = {}
}

@(private)
baseline_kind_for :: proc "contextless" (kind: codec.Baseline_Kind) -> replay.Baseline_Kind {
	switch kind {
	case .None:                       return .None
	case .Commit_Verified:            return .Commit_Verified
	case .Working_Tree_Observational: return .Working_Tree_Observational
	}
	return .None
}

// seek_to moves replay to the moment a playhead time names.
//
// The playhead is a wall-clock instant and replay is ordered by sequence, so
// this resolves one to the other. docs/03 makes sequence authoritative for
// replay while wall time is display metadata, which is exactly why the
// conversion happens here rather than the engine taking a timestamp.
seek_to :: proc(
	session: ^Replay_Session,
	trace: ^codec.Trace,
	playhead_ns: i64,
) -> (
	moved: bool,
) {
	if !session.usable {
		return false
	}

	target := sequence_at_time(trace, playhead_ns)
	if target == session.position {
		return false
	}

	replay.seek(&session.timeline, &session.engine, target)
	session.position = target
	return true
}

// sequence_at_time returns the latest sequence at or before an instant.
//
// Events are time-ordered, so this is a binary search. A playhead before the
// first event yields zero, which the engine treats as the baseline.
@(private)
sequence_at_time :: proc(trace: ^codec.Trace, playhead_ns: i64) -> model.Sequence {
	low := 0
	high := len(trace.events)
	for low < high {
		middle := low + (high - low) / 2
		if event_time_of(trace.events[middle]) <= playhead_ns {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == 0 {
		return 0
	}
	return trace.events[low - 1].sequence
}

@(private)
event_time_of :: proc "contextless" (event: model.Event) -> i64 {
	if .Has_Wall_Time in event.flags {
		return event.wall_time_ns
	}
	if .Has_Monotonic_Offset in event.flags {
		return event.monotonic_offset_ns
	}
	return i64(event.sequence)
}

// resolve_path returns the reconstructed state of a path at the current
// position.
resolve_path :: proc(
	session: ^Replay_Session,
	path: model.Entity_Id,
) -> replay.Resolved_Content {
	if !session.usable || path == model.NO_ENTITY {
		return replay.Resolved_Content{status = .Unknown_Path}
	}
	return replay.resolve(&session.engine, path)
}

// previous_mutation_content returns a path's content before the most recent
// change at or before the current position.
//
// This is what the diff panel's "since previous change" mode compares against.
// It seeks a second engine walk rather than caching the previous state,
// because the previous state depends on where the playhead is and caching it
// would go stale the moment the user moved.
previous_mutation_content :: proc(
	session: ^Replay_Session,
	trace: ^codec.Trace,
	path: model.Entity_Id,
	allocator := context.allocator,
) -> (
	content: []byte,
	available: bool,
) {
	if !session.usable || path == model.NO_ENTITY {
		return nil, false
	}

	// Find the last mutation to this path at or before the current position.
	target := -1
	for mutation, index in session.timeline.mutations {
		if session.sequences[index] > session.position {
			break
		}
		if mutation.path == path {
			target = index
		}
	}
	if target < 0 {
		return nil, false
	}

	// Reconstruct the state immediately before it. Seeking the shared engine
	// would disturb what every other panel is reading this frame, so this uses
	// its own walk and restores the position afterwards.
	saved := session.position
	defer {
		replay.seek(&session.timeline, &session.engine, saved)
		session.position = saved
	}

	before := model.Sequence(0)
	if target > 0 {
		before = session.sequences[target - 1]
	}
	replay.seek(&session.timeline, &session.engine, before)

	resolved := replay.resolve(&session.engine, path)
	if !replay.has_content(resolved) {
		return nil, false
	}

	// Copied because the engine's content store is about to be seeked back,
	// which can reuse the buffer the result borrows.
	copied := make([]byte, len(resolved.content), allocator)
	copy(copied, resolved.content)
	return copied, true
}

// content_at reconstructs a path at an arbitrary moment.
//
// The shared engine is seeked and restored, because every panel in a frame
// reads the same engine and leaving it moved would make them describe
// different instants — the divergence docs/01 forbids.
//
// The result is copied: the engine's content store is reused as it seeks, so a
// borrowed slice would not survive the restore.
content_at :: proc(
	session: ^Replay_Session,
	trace: ^codec.Trace,
	path: model.Entity_Id,
	playhead_ns: i64,
	allocator := context.allocator,
) -> (
	content: []byte,
	available: bool,
) {
	if !session.usable || path == model.NO_ENTITY {
		return nil, false
	}

	saved := session.position
	defer {
		replay.seek(&session.timeline, &session.engine, saved)
		session.position = saved
	}

	replay.seek(&session.timeline, &session.engine, sequence_at_time(trace, playhead_ns))
	resolved := replay.resolve(&session.engine, path)
	if !replay.has_content(resolved) {
		// An empty file and an unreconstructable one are different facts. The
		// caller distinguishes them by checking the current status separately;
		// here, absence of content means there is nothing to compare against.
		return nil, false
	}

	copied := make([]byte, len(resolved.content), allocator)
	copy(copied, resolved.content)
	return copied, true
}

// baseline_content returns a path's state at the start of the session.
//
// Used by the "since session start" mode. Distinct from content_at with a
// zero playhead because a session's first instant is not necessarily zero,
// and using zero would compare against a moment before the trace begins.
baseline_content :: proc(
	session: ^Replay_Session,
	path: model.Entity_Id,
	allocator := context.allocator,
) -> (
	content: []byte,
	available: bool,
) {
	if !session.usable || path == model.NO_ENTITY {
		return nil, false
	}

	saved := session.position
	defer {
		replay.seek(&session.timeline, &session.engine, saved)
		session.position = saved
	}

	replay.seek(&session.timeline, &session.engine, 0)
	resolved := replay.resolve(&session.engine, path)
	if !replay.has_content(resolved) {
		return nil, false
	}

	copied := make([]byte, len(resolved.content), allocator)
	copy(copied, resolved.content)
	return copied, true
}

// gap_count reports how many mutations could not be replayed so far.
//
// Surfaced so the interface can say the reconstruction is partial rather than
// leaving a user to infer it from an unexpected panel state.
replay_gap_count :: proc(session: ^Replay_Session) -> int {
	if !session.usable {
		return 0
	}
	return replay.gap_count(&session.engine)
}
