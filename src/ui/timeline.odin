package ui

import "src:trace/codec"
import "src:trace/model"

// Timeline virtualization and hit testing.
//
// docs/07-rendering.md: only events intersecting the visible time interval and
// enabled lanes generate draw instances, and "a range query returns a compact
// visible-event view; the panel does not scan the full session each frame."
//
// Events are stored in sequence order, which for a well-formed trace is also
// time order, so the visible window is found by binary search rather than by
// scanning. At 100,000 events that is the difference between reading a handful
// of entries and reading all of them sixty times a second.

// Visible_Event is one event positioned for drawing.
//
// Bounds are computed once here and used by both the renderer and hit testing,
// which is what keeps a click landing on what the user sees.
Visible_Event :: struct {
	id:       model.Event_Id,
	sequence: model.Sequence,
	kind:     model.Event_Kind,
	lane:     Lane,
	bounds:   Bounds,
	// The entity this event concerns, for labeling and focus.
	entity: model.Entity_Id,
	// True when the event is an outcome that failed, which docs/07 requires
	// to stay visible even when density forces aggregation.
	is_failure: bool,
}

// Lane_Filter selects which swimlanes are shown.
//
// An empty set means every lane, not none: a filter nobody configured should
// not hide the whole timeline. docs/01 also requires that "a hidden filter
// must never explain an apparently missing event", which is why the visible
// set is returned alongside the results below.
Lane_Filter :: bit_set[Lane; u8]

ALL_LANES :: Lane_Filter{
	.Conversation,
	.Tools,
	.Files,
	.Commands,
	.Outcomes,
	.Errors,
	.Annotations,
}

// Visible_Set is the result of a range query.
Visible_Set :: struct {
	events: [dynamic]Visible_Event,
	// Events inside the interval that a lane filter excluded. Reported so the
	// interface can say a filter is hiding results rather than leaving the
	// user to wonder where an event went.
	filtered_out: int,
	// Events inside the interval whose lane is shown. Equal to len(events)
	// unless a density cap applied.
	total_in_range: int,
}

visible_set_destroy :: proc(set: ^Visible_Set) {
	delete(set.events)
	set^ = {}
}

// first_at_or_after returns the index of the first event at or after a time.
//
// Binary search over a slice the caller guarantees is time-ordered. docs/03
// makes sequence authoritative and importers preserve source order, so this
// holds for any trace that passed validation.
first_at_or_after :: proc(events: []model.Event, time_ns: i64) -> int {
	low := 0
	high := len(events)
	for low < high {
		middle := low + (high - low) / 2
		if event_time(events[middle]) < time_ns {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

// event_time returns the timestamp used for timeline placement.
//
// docs/03 makes sequence authoritative for replay and wall time "display and
// correlation metadata". An event without a trustworthy timestamp still has to
// appear somewhere, so its monotonic offset is used, and failing that its
// sequence stands in as a synthetic ordinate. The alternative — dropping it —
// would hide a recorded event because its clock was unreliable.
event_time :: proc "contextless" (event: model.Event) -> i64 {
	if .Has_Wall_Time in event.flags {
		return event.wall_time_ns
	}
	if .Has_Monotonic_Offset in event.flags {
		return event.monotonic_offset_ns
	}
	return i64(event.sequence)
}

// event_duration returns the drawn duration of an event.
event_duration :: proc "contextless" (event: model.Event) -> i64 {
	if .Has_Duration in event.flags && event.duration_ns > 0 {
		return event.duration_ns
	}
	return 0
}

// Timeline_Index is per-trace derived data the panel holds across frames.
//
// Currently one field, but it exists as a struct because a package-level cache
// would be shared mutable state, which docs/02 rules out: the main thread owns
// UI state and nothing else may write it. Making the caller hold it also makes
// the lifetime obvious — it dies with the trace it describes.
Timeline_Index :: struct {
	// The longest event duration in the trace.
	//
	// query_visible needs this to bound its backward search. Computing it per
	// frame would be the full scan virtualization exists to avoid, and it
	// cannot change while a trace is open, so it is computed once.
	max_duration: i64,
}

// build_index computes the derived data a timeline panel needs.
build_index :: proc(trace: ^codec.Trace) -> Timeline_Index {
	index: Timeline_Index
	for event in trace.events {
		duration := event_duration(event)
		if duration > index.max_duration {
			index.max_duration = duration
		}
	}
	return index
}

// MAX_VISIBLE_EVENTS caps how many events one query returns.
//
// docs/07 requires aggregation at distant zoom rather than unbounded instance
// generation, and the graphics spike measured a million instances at 3 ms with
// a 7.98 ms worst frame — too close to the budget to be safe. This cap is the
// point past which the caller should switch to aggregated bins.
MAX_VISIBLE_EVENTS :: 200_000

// query_visible returns the events intersecting a viewport.
//
// The result borrows nothing from the trace beyond identifiers, so it stays
// valid independently of the trace's chunk cache.
query_visible :: proc(
	trace: ^codec.Trace,
	index: Timeline_Index,
	viewport: Viewport,
	filter: Lane_Filter = ALL_LANES,
	allocator := context.allocator,
) -> Visible_Set {
	set := Visible_Set {
		events = make([dynamic]Visible_Event, 0, 1024, allocator),
	}

	lanes := filter
	if lanes == {} {
		lanes = ALL_LANES
	}

	events := trace.events[:]
	if len(events) == 0 {
		return set
	}

	// Start before the visible interval by the longest duration in the trace.
	//
	// An event that began earlier may still be running into view. Any fixed
	// lookback is a guess that silently drops whatever runs longer than it —
	// a build that started ten minutes ago would vanish from a one-minute
	// window. Deriving the bound from the actual maximum duration makes the
	// search exact: nothing starting before it can still be running.
	search_from := viewport.start_ns - index.max_duration
	first := first_at_or_after(events, search_from)

	view_end := end_ns(viewport)

	for position := first; position < len(events); position += 1 {
		event := events[position]
		time_ns := event_time(event)

		// Events are time-ordered, so once past the right edge nothing later
		// can intersect and the scan stops.
		if time_ns > view_end {
			break
		}

		duration := event_duration(event)
		if !intersects(viewport, time_ns, duration) {
			continue
		}

		lane := lane_for_kind(event.kind)
		if lane not_in lanes {
			set.filtered_out += 1
			continue
		}

		set.total_in_range += 1
		if len(set.events) >= MAX_VISIBLE_EVENTS {
			// Past the cap the caller must aggregate. Continuing to count
			// gives it the figure it needs to say so.
			continue
		}

		append(
			&set.events,
			Visible_Event {
				id = event.id,
				sequence = event.sequence,
				kind = event.kind,
				lane = lane,
				bounds = event_bounds(viewport, time_ns, duration),
				entity = event.primary_entity_id,
				is_failure = is_failure_event(trace, event),
			},
		)
	}

	return set
}

// needs_aggregation reports whether a query exceeded the instance cap.
needs_aggregation :: proc "contextless" (set: Visible_Set) -> bool {
	return set.total_in_range > MAX_VISIBLE_EVENTS
}

// is_failure_event reports whether an event is a recorded failure.
//
// docs/07: aggregation "must preserve the visibility of failures and explicit
// bookmarks even when density is high", so failures are marked at query time
// and the binning below never drops one.
is_failure_event :: proc(trace: ^codec.Trace, event: model.Event) -> bool {
	#partial switch event.kind {
	case .Tool_Error, .Explicit_Error:
		return true

	case .Test_Case_Result, .Test_Run_End:
		if payload, ok := model.get_test(&trace.payloads, event.payload); ok {
			return model.is_failure(payload.status)
		}

	case .Command_End, .Build_Result, .Lint_Result:
		if payload, ok := model.get_command(&trace.payloads, event.payload); ok {
			return model.is_failure(payload.status)
		}

	case .Diagnostic:
		if payload, ok := model.get_diagnostic(&trace.payloads, event.payload); ok {
			return payload.severity >= .Error
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// Hit identifies what a pointer position landed on.
Hit :: struct {
	event: model.Event_Id,
	lane:  Lane,
	found: bool,
}

// hit_test returns the event at a pixel position.
//
// It searches the visible set rather than the trace, so it can only select
// something the user can actually see, and it uses the bounds computed at
// query time — the same ones the renderer drew. docs/07 prohibits recomputing
// this because two formulas drift.
//
// When several events overlap, the last one wins: later events are drawn on
// top, so the topmost is what the user believes they clicked.
hit_test :: proc(set: ^Visible_Set, layout: Lane_Layout, x: f32, y: f32) -> Hit {
	lane, in_lane := lane_at_y(layout, y)
	if !in_lane {
		return Hit{}
	}

	result := Hit{lane = lane}
	for event in set.events {
		if event.lane != lane {
			continue
		}
		if bounds_contains(event.bounds, x) {
			result.event = event.id
			result.found = true
		}
	}
	return result
}

// nearest_event returns the visible event closest to a pixel position.
//
// Used for keyboard navigation and for clicks that fall between events, where
// selecting nothing is less useful than selecting the obvious neighbour.
nearest_event :: proc(set: ^Visible_Set, lane: Lane, x: f32) -> Hit {
	result := Hit{lane = lane}
	best := max(f32)

	for event in set.events {
		if event.lane != lane {
			continue
		}
		distance := f32(0)
		if x < event.bounds.x0 {
			distance = event.bounds.x0 - x
		} else if x > event.bounds.x1 {
			distance = x - event.bounds.x1
		}
		if distance < best {
			best = distance
			result.event = event.id
			result.found = true
		}
	}
	return result
}

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------

// Bin is one screen-space aggregation bucket.
//
// docs/07: at distant zoom, events aggregate into fixed screen-space bins
// containing event count by kind, total duration, outcome status counts,
// mutation density, and error and retry markers.
Bin :: struct {
	x0, x1: f32,
	// Counts that drive the bin's appearance.
	total:      int,
	mutations:  int,
	outcomes:   int,
	failures:   int,
	errors:     int,
	// The first failing event in the bin, so selecting the bin can navigate
	// to something specific rather than to a range.
	first_failure: model.Event_Id,
}

// BIN_WIDTH is the screen-space width of one aggregation bucket.
//
// Four pixels keeps individual bins distinguishable at a glance while reducing
// a hundred thousand events to a few hundred draw instances.
BIN_WIDTH :: f32(4)

// Aggregate_Set is a binned view of a lane.
Aggregate_Set :: struct {
	bins: [dynamic]Bin,
	// Failures are kept as individual events regardless of density, per
	// docs/07, so they never disappear into a bin's average.
	failures: [dynamic]Visible_Event,
}

aggregate_set_destroy :: proc(set: ^Aggregate_Set) {
	delete(set.bins)
	delete(set.failures)
	set^ = {}
}

// aggregate reduces a visible set to screen-space bins.
//
// Failures are extracted rather than counted away: a bin says how much
// happened, and a preserved failure says what went wrong. Losing the second to
// summarize the first would defeat the purpose of the timeline.
aggregate :: proc(
	set: ^Visible_Set,
	viewport: Viewport,
	lane: Lane,
	allocator := context.allocator,
) -> Aggregate_Set {
	bin_count := int(viewport.width / BIN_WIDTH) + 1
	if bin_count < 1 {
		bin_count = 1
	}

	result := Aggregate_Set {
		bins     = make([dynamic]Bin, bin_count, allocator),
		failures = make([dynamic]Visible_Event, 0, 32, allocator),
	}

	for index in 0 ..< bin_count {
		x0 := viewport.origin_x + f32(index) * BIN_WIDTH
		result.bins[index] = Bin{x0 = x0, x1 = x0 + BIN_WIDTH}
	}

	for event in set.events {
		if event.lane != lane {
			continue
		}

		if event.is_failure {
			append(&result.failures, event)
		}

		index := int((event.bounds.x0 - viewport.origin_x) / BIN_WIDTH)
		if index < 0 {
			index = 0
		}
		if index >= bin_count {
			index = bin_count - 1
		}

		bin := &result.bins[index]
		bin.total += 1
		if model.is_mutation(event.kind) {
			bin.mutations += 1
		}
		if model.is_outcome(event.kind) {
			bin.outcomes += 1
		}
		if event.is_failure {
			bin.failures += 1
			if bin.first_failure == model.NO_EVENT {
				bin.first_failure = event.id
			}
		}
		if event.kind == .Tool_Error || event.kind == .Explicit_Error {
			bin.errors += 1
		}
	}

	return result
}

// peak_density returns the largest event count in any bin, for scaling.
peak_density :: proc(set: ^Aggregate_Set) -> int {
	peak := 0
	for bin in set.bins {
		if bin.total > peak {
			peak = bin.total
		}
	}
	return peak
}
