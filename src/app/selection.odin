package app

import "src:trace/model"

// The global selection.
//
// docs/01-user-experience.md: Norn has one global selection — session, point
// or range in time, and an optional focused entity — and "every panel reacts
// to that selection. The application must not allow the timeline to show one
// moment while the diff or graph silently shows another."
//
// One struct, one owner. A panel that kept its own idea of the current moment
// is exactly the divergence that rule forbids, so panels read this and never
// store a copy.

// Focus_Kind discriminates what is focused, when anything is.
Focus_Kind :: enum u8 {
	None   = 0,
	Event  = 1,
	Entity = 2,
}

// Selection is the application's single source of truth for what is selected.
Selection :: struct {
	// The moment every panel renders. docs/01 makes time the primary axis.
	playhead_ns: i64,
	// False before the user has chosen a moment. Distinguished from zero
	// because zero is a real instant and drawing a playhead there would claim
	// a selection nobody made.
	has_playhead: bool,

	// The selected event, which is what the inspector describes.
	event: model.Event_Id,

	// The focused entity, which filters the repository map and diff panels.
	focus_kind:   Focus_Kind,
	focus_entity: model.Entity_Id,

	// Comparison range, set with the bracket keys.
	range_start_ns: i64,
	range_end_ns:   i64,
	has_range_start: bool,
	has_range_end:   bool,
}

// has_range reports whether a complete comparison range is set.
//
// Both ends are required: a range with only a start is a user midway through
// setting one, and computing a comparison from it would show a diff they did
// not ask for.
has_range :: proc "contextless" (selection: Selection) -> bool {
	return selection.has_range_start && selection.has_range_end
}

// range_bounds returns the ordered comparison range.
//
// Ordered because the brackets can be pressed in either order, and a user who
// marks the end first means the same range as one who marks the start first.
range_bounds :: proc "contextless" (selection: Selection) -> (from: i64, to: i64) {
	from = selection.range_start_ns
	to = selection.range_end_ns
	if from > to {
		from, to = to, from
	}
	return from, to
}

// has_focus reports whether anything is focused.
has_focus :: proc "contextless" (selection: Selection) -> bool {
	return selection.focus_kind != .None
}

// clear_focus removes the focused entity, leaving time and event selection.
clear_focus :: proc(selection: ^Selection) {
	selection.focus_kind = .None
	selection.focus_entity = model.NO_ENTITY
}

// clear_range removes the comparison range.
clear_range :: proc(selection: ^Selection) {
	selection.has_range_start = false
	selection.has_range_end = false
	selection.range_start_ns = 0
	selection.range_end_ns = 0
}
