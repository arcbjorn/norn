package replay

import "src:trace/model"

// Seeking, snapshots, and range comparison.
//
// docs/06 seeking: choose the nearest snapshot at or before the target
// sequence, then apply mutations forward only for affected paths. Snapshot
// content is derived and can be rebuilt, which is why nothing here is written
// to the trace.

// SNAPSHOT_INTERVAL is the version-one policy: snapshot after every 256
// replayable mutations. docs/06 marks this tunable after measurement.
SNAPSHOT_INTERVAL :: 256

// Snapshot is a repository state captured at a mutation boundary.
//
// `index` is the position in the mutation slice *after* which this state
// holds, so restoring it means the first `index` mutations have been applied.
Snapshot :: struct {
	index:    int,
	sequence: model.Sequence,
	state:    Repository_State,
}

// Timeline owns the mutations, the baseline, and the snapshots taken over them.
//
// It is the object a viewer holds: seeking is a method on the whole history
// rather than on a single engine walk, because a seek may need to restart from
// an earlier snapshot.
Timeline :: struct {
	mutations: []model.Mutation,
	// Event sequence for each mutation, parallel to `mutations`. Mutations
	// reference events by identifier, but seeking is expressed in sequence,
	// which is the authoritative order per docs/03.
	sequences: []model.Sequence,
	baseline:  ^Baseline,
	snapshots: [dynamic]Snapshot,
}

// timeline_init prepares a timeline over an ordered mutation slice.
//
// `mutations` and `sequences` are borrowed and must remain valid and in
// increasing sequence order for the timeline's lifetime.
timeline_init :: proc(
	timeline: ^Timeline,
	mutations: []model.Mutation,
	sequences: []model.Sequence,
	baseline: ^Baseline,
	allocator := context.allocator,
) {
	timeline.mutations = mutations
	timeline.sequences = sequences
	timeline.baseline = baseline
	timeline.snapshots = make([dynamic]Snapshot, 0, 8, allocator)
}

timeline_destroy :: proc(timeline: ^Timeline) {
	for &snapshot in timeline.snapshots {
		state_destroy(&snapshot.state)
	}
	delete(timeline.snapshots)
	timeline^ = {}
}

// timeline_build_snapshots walks the whole history once, capturing a snapshot
// at the baseline and after every SNAPSHOT_INTERVAL mutations.
//
// docs/06 always snapshots the verified baseline, because every seek that
// finds no nearer snapshot restarts there.
timeline_build_snapshots :: proc(
	timeline: ^Timeline,
	engine: ^Engine,
	allocator := context.allocator,
) {
	engine_reset(engine, timeline.baseline)

	append(
		&timeline.snapshots,
		Snapshot {
			index = 0,
			sequence = 0,
			state = state_clone(&engine.state, allocator),
		},
	)

	for index in 0 ..< len(timeline.mutations) {
		apply_mutation(engine, timeline.mutations[index])

		applied := index + 1
		engine.applied = applied
		engine.position = timeline.sequences[index]
		if applied % SNAPSHOT_INTERVAL == 0 {
			append(
				&timeline.snapshots,
				Snapshot {
					index = applied,
					sequence = timeline.sequences[index],
					state = state_clone(&engine.state, allocator),
				},
			)
		}
	}
}

// nearest_snapshot returns the latest snapshot at or before `index`.
@(private)
nearest_snapshot :: proc(timeline: ^Timeline, index: int) -> (snapshot: ^Snapshot, found: bool) {
	best: ^Snapshot
	for &candidate in timeline.snapshots {
		if candidate.index <= index {
			if best == nil || candidate.index > best.index {
				best = &candidate
			}
		}
	}
	if best == nil {
		return nil, false
	}
	return best, true
}

// mutation_count_at returns how many mutations have sequence <= target.
//
// Mutations are in increasing sequence order, so this is a binary search. It
// answers "how far into the history is this moment", which is what both
// seeking and range comparison need.
mutation_count_at :: proc(timeline: ^Timeline, target: model.Sequence) -> int {
	low := 0
	high := len(timeline.sequences)
	for low < high {
		middle := low + (high - low) / 2
		if timeline.sequences[middle] <= target {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

// seek advances or rewinds the engine to the state at `target`.
//
// Seeking forward from the current position replays only the mutations in
// between. Seeking backward restarts from the nearest snapshot, because
// mutations are not invertible in general: a modify records what the content
// became, not what it was.
seek :: proc(timeline: ^Timeline, engine: ^Engine, target: model.Sequence) {
	wanted := mutation_count_at(timeline, target)
	current := engine.applied

	// Choose the cheapest correct starting point.
	//
	// Continuing from the current state is only valid when it is already at or
	// before the target *and* actually reflects a walk from the baseline. A
	// snapshot restore is otherwise preferred, and the baseline is the
	// fallback when no snapshot precedes the target.
	start := 0
	snapshot, found := nearest_snapshot(timeline, wanted)

	if current <= wanted && (snapshot == nil || snapshot.index <= current) {
		// The engine is already between the best snapshot and the target, so
		// replaying forward from here does the least work.
		start = current
	} else if found {
		restore_state(engine, &snapshot.state)
		start = snapshot.index
	} else {
		engine_reset(engine, timeline.baseline)
		start = 0
	}

	// Outcomes describe the mutations applied to reach the current state. A
	// seek that rewinds must discard the ones it is undoing, or gap counts
	// would accumulate across seeks and report failures twice.
	truncate_outcomes(engine, start)

	for index in start ..< wanted {
		apply_mutation(engine, timeline.mutations[index])
	}

	engine.position = target
	engine.applied = wanted
}

// restore_state replaces the engine's state with a copy of a snapshot,
// releasing the state it had.
@(private)
restore_state :: proc(engine: ^Engine, source: ^Repository_State) {
	clear(&engine.state.paths)
	for key, value in source.paths {
		engine.state.paths[key] = value
	}
}

// truncate_outcomes drops outcome records beyond `count` applied mutations.
@(private)
truncate_outcomes :: proc(engine: ^Engine, count: int) {
	if count <= 0 {
		clear(&engine.outcomes)
		return
	}
	if count < len(engine.outcomes) {
		resize(&engine.outcomes, count)
	}
}

// seek_to_index moves to a mutation index rather than a sequence, which tests
// and the snapshot-equivalence property use directly.
seek_to_index :: proc(timeline: ^Timeline, engine: ^Engine, index: int) {
	target := model.Sequence(0)
	if index > 0 && index <= len(timeline.sequences) {
		target = timeline.sequences[index - 1]
	}
	seek(timeline, engine, target)
}

// ---------------------------------------------------------------------------
// Range comparison
// ---------------------------------------------------------------------------

// Change_Kind classifies what happened to a path across a comparison range.
Change_Kind :: enum u8 {
	Unchanged = 0,
	Created   = 1,
	Modified  = 2,
	Deleted   = 3,
	Renamed   = 4,
}

change_kind_name :: proc "contextless" (kind: Change_Kind) -> string {
	switch kind {
	case .Unchanged: return "unchanged"
	case .Created:   return "created"
	case .Modified:  return "modified"
	case .Deleted:   return "deleted"
	case .Renamed:   return "renamed"
	}
	return "unknown"
}

// Path_Change is one path's difference between two points in the session.
Path_Change :: struct {
	path:        model.Entity_Id,
	kind:        Change_Kind,
	before_hash: model.Blob_Digest,
	after_hash:  model.Blob_Digest,
	// True when a replay gap affects either endpoint, so the comparison cannot
	// be trusted as complete. docs/06 requires gaps affecting a comparison to
	// be reported alongside it.
	affected_by_gap: bool,
}

// Comparison is the result of comparing two points, per docs/06.
Comparison :: struct {
	from:    model.Sequence,
	to:      model.Sequence,
	changes: [dynamic]Path_Change,
	// Count of paths whose comparison is degraded by a replay gap.
	gap_count: int,
}

comparison_destroy :: proc(comparison: ^Comparison) {
	delete(comparison.changes)
	comparison^ = {}
}

// compare_range reports how the repository differs between sequences A and B.
//
// Both endpoints are reconstructed and their path states compared. A path
// touched and then restored to identical content reports Unchanged, because
// the comparison describes the difference between two moments rather than the
// route taken between them; the timeline already shows the route.
compare_range :: proc(
	timeline: ^Timeline,
	engine: ^Engine,
	from: model.Sequence,
	to: model.Sequence,
	allocator := context.allocator,
) -> Comparison {
	low := from
	high := to
	if low > high {
		low, high = high, low
	}

	comparison := Comparison {
		from    = low,
		to      = high,
		changes = make([dynamic]Path_Change, 0, 16, allocator),
	}

	// Capture the earlier state, then advance to the later one.
	seek(timeline, engine, low)
	before := state_clone(&engine.state, context.temp_allocator)
	defer state_destroy(&before)

	// Digests are resolved while the earlier state is current, because the
	// content store is shared and identifiers alone would not tell us what the
	// bytes were.
	before_digests := make(map[model.Entity_Id]model.Blob_Digest, len(before.paths), context.temp_allocator)
	defer delete(before_digests)
	for path, state in before.paths {
		if state.exists && has_ref(state.content) {
			if content, ok := engine_content(engine, state.content); ok {
				before_digests[path] = model.digest_content(content)
			}
		}
	}

	seek(timeline, engine, high)

	// Every path known at either endpoint is considered.
	seen := make(map[model.Entity_Id]bool, len(before.paths), context.temp_allocator)
	defer delete(seen)

	for path, after_state in engine.state.paths {
		seen[path] = true
		before_state, had_before := before.paths[path]

		change := Path_Change{path = path}
		change.affected_by_gap =
			after_state.verification == .Gap ||
			(had_before && before_state.verification == .Gap)

		if digest, ok := before_digests[path]; ok {
			change.before_hash = digest
		}
		if after_state.exists && has_ref(after_state.content) {
			if content, ok := engine_content(engine, after_state.content); ok {
				change.after_hash = model.digest_content(content)
			}
		}

		existed_before := had_before && before_state.exists
		switch {
		case !existed_before && after_state.exists:
			change.kind = .Created
		case existed_before && !after_state.exists:
			change.kind = .Deleted
		case existed_before && after_state.exists:
			if model.digest_equal(change.before_hash, change.after_hash) &&
			   !change.affected_by_gap {
				change.kind = .Unchanged
			} else {
				change.kind = .Modified
			}
		case:
			change.kind = .Unchanged
		}

		if change.kind != .Unchanged {
			if change.affected_by_gap {
				comparison.gap_count += 1
			}
			append(&comparison.changes, change)
		}
	}

	// Paths present before but absent from the later state entirely.
	for path, before_state in before.paths {
		if seen[path] || !before_state.exists {
			continue
		}
		change := Path_Change {
			path = path,
			kind = .Deleted,
			affected_by_gap = before_state.verification == .Gap,
		}
		if digest, ok := before_digests[path]; ok {
			change.before_hash = digest
		}
		if change.affected_by_gap {
			comparison.gap_count += 1
		}
		append(&comparison.changes, change)
	}

	return comparison
}
