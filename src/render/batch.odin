package render

// Batching.
//
// docs/07-rendering.md: "similar primitives are batched by pipeline, texture
// atlas, and clip rectangle." Each of those three is a reason the GPU cannot
// continue an existing draw call, so a batch is a maximal run of commands that
// share all three.
//
// The pass runs on the CPU with no GPU types involved, which keeps it testable
// and keeps the backend free to consume batches however its API prefers.

// Pipeline identifies the shader and state a command needs.
//
// Several command kinds share a pipeline: a solid rectangle, an outline, and a
// rounded rectangle are all the same shader with different parameters, so
// grouping them avoids a state change that buys nothing.
Pipeline :: enum u8 {
	// Untextured shapes: rectangles, outlines, rounded rectangles, circles.
	Shape = 0,
	// Line segments, which need their own vertex expansion.
	Line = 1,
	// Textured quads sampling a glyph atlas.
	Glyph = 2,
	// Textured quads sampling an ordinary texture.
	Texture = 3,
}

// pipeline_for returns the pipeline a command kind requires.
pipeline_for :: proc "contextless" (kind: Command_Kind) -> Pipeline {
	switch kind {
	case .Rect, .Rect_Outline, .Rounded_Rect, .Circle:
		return .Shape
	case .Line:
		return .Line
	case .Glyph:
		return .Glyph
	case .Textured:
		return .Texture
	}
	return .Shape
}

// Batch is a contiguous run of commands the backend can submit together.
//
// `first` and `count` index the sorted order produced by build_batches, not
// the draw list's append order.
Batch :: struct {
	pipeline: Pipeline,
	atlas:    u32,
	clip:     u32,
	first:    int,
	count:    int,
}

// Batched_Frame is the result of the batching pass.
Batched_Frame :: struct {
	// Command indices into the draw list, in submission order.
	order: [dynamic]int,
	// Runs over `order`.
	batches: [dynamic]Batch,
}

batched_frame_init :: proc(frame: ^Batched_Frame, allocator := context.allocator) {
	frame.order = make([dynamic]int, 0, 4096, allocator)
	frame.batches = make([dynamic]Batch, 0, 64, allocator)
}

batched_frame_destroy :: proc(frame: ^Batched_Frame) {
	delete(frame.order)
	delete(frame.batches)
	frame^ = {}
}

batched_frame_reset :: proc(frame: ^Batched_Frame) {
	clear(&frame.order)
	clear(&frame.batches)
}

// sort_key packs the fields that determine submission order.
//
// Layer is most significant because painter's order is a correctness property:
// a panel that draws a background after its content must still see the
// background behind. Pipeline, atlas, and clip follow as batching hints, and
// the original index breaks ties so the sort is stable — two commands with
// identical keys keep the order the panel emitted them in, which is what a
// panel relies on when it draws overlapping shapes.
@(private)
sort_key :: proc "contextless" (command: Command, index: int) -> u64 {
	layer := u64(command.layer)
	pipeline := u64(pipeline_for(command.kind))
	atlas := u64(command.source.atlas)
	clip := u64(command.clip)

	// 16 bits layer | 2 bits pipeline | 10 bits atlas | 12 bits clip | 24 index.
	return layer << 48 | pipeline << 46 | (atlas & 0x3FF) << 36 | (clip & 0xFFF) << 24 |
		u64(index) & 0xFF_FFFF
}

// build_batches orders commands and groups them into draw calls.
//
// The caller owns `frame` and reuses it across frames.
build_batches :: proc(list: ^Draw_List, frame: ^Batched_Frame) {
	batched_frame_reset(frame)
	if len(list.commands) == 0 {
		return
	}

	// Sort indices rather than commands: a Command is large enough that moving
	// them during the sort costs more than the indirection at submission.
	keys := make([]u64, len(list.commands), context.temp_allocator)
	defer delete(keys, context.temp_allocator)

	for command, index in list.commands {
		keys[index] = sort_key(command, index)
		append(&frame.order, index)
	}

	sort_by_key(frame.order[:], keys)

	// Walk the sorted order and start a new batch whenever any of the three
	// grouping dimensions changes.
	current := Batch {
		pipeline = pipeline_for(list.commands[frame.order[0]].kind),
		atlas    = list.commands[frame.order[0]].source.atlas,
		clip     = list.commands[frame.order[0]].clip,
		first    = 0,
		count    = 0,
	}

	for position in 0 ..< len(frame.order) {
		command := list.commands[frame.order[position]]
		pipeline := pipeline_for(command.kind)

		if pipeline != current.pipeline ||
		   command.source.atlas != current.atlas ||
		   command.clip != current.clip {
			if current.count > 0 {
				append(&frame.batches, current)
			}
			current = Batch {
				pipeline = pipeline,
				atlas    = command.source.atlas,
				clip     = command.clip,
				first    = position,
				count    = 0,
			}
		}
		current.count += 1
	}

	if current.count > 0 {
		append(&frame.batches, current)
	}
}

// sort_by_key sorts indices by their keys, ascending.
//
// Insertion sort over a mostly-ordered array: panels emit commands in roughly
// layer order already, so the input is nearly sorted and this runs close to
// linear. A comparison sort would be asymptotically better on adversarial
// input, which frame construction does not produce.
@(private)
sort_by_key :: proc(order: []int, keys: []u64) {
	for position in 1 ..< len(order) {
		index := order[position]
		key := keys[index]

		slot := position
		for slot > 0 && keys[order[slot - 1]] > key {
			order[slot] = order[slot - 1]
			slot -= 1
		}
		order[slot] = index
	}
}

// Frame_Stats summarizes a batched frame for the developer overlay.
//
// docs/07 requires the overlay to report draw calls and instances, which are
// exactly these two figures.
Frame_Stats :: struct {
	commands:    int,
	draw_calls:  int,
	// The largest batch, which indicates how well batching is working: many
	// tiny batches mean state is changing too often.
	largest_batch: int,
}

frame_stats :: proc(list: ^Draw_List, frame: ^Batched_Frame) -> Frame_Stats {
	stats := Frame_Stats {
		commands   = len(list.commands),
		draw_calls = len(frame.batches),
	}
	for batch in frame.batches {
		if batch.count > stats.largest_batch {
			stats.largest_batch = batch.count
		}
	}
	return stats
}
