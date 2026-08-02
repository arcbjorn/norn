package text_spike

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import stbtt "vendor:stb/truetype"
import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

// Phase-zero text spike.
//
// docs/11-roadmap.md phase zero: render crisp text at standard and high-DPI
// scales. docs/07 adds the caching rule: the glyph atlas is generated lazily
// and cached by font, size, and scale factor, and no frame may exceed 50 ms
// on a glyph-cache miss batch.
//
// Throwaway, like the graphics spike. It exists to answer whether stb_truetype
// plus a GPU atlas meets those requirements before any UI depends on them.
//
// Run with:  scripts/norn.sh spike text [--frames N]

// Norn renders two text families per docs/07: monospace for source text and a
// separate readable face for interface text. The spike uses the monospace one
// because diffs and command output are the demanding case.
FONT_PATH :: "/System/Library/Fonts/SFNSMono.ttf"

// ATLAS_SIZE is the backing texture for one (font, size, scale) combination.
// 1024 holds the printable ASCII range several times over at UI sizes.
ATLAS_SIZE :: 1024

// FIRST_GLYPH and GLYPH_COUNT cover printable ASCII. Real usage needs lazy
// population for arbitrary codepoints; the spike measures the bulk case.
FIRST_GLYPH :: 32
GLYPH_COUNT :: 95

Glyph :: struct {
	// Position in the atlas texture, in pixels.
	x0, y0, x1, y1: u16,
	// Offset from the pen position to the top-left of the bitmap.
	offset_x, offset_y: f32,
	advance:            f32,
}

// Atlas is one rasterized font at one size and scale factor.
//
// docs/07 keys the cache by font, size, and scale factor together. Scale is
// part of the key because a 13-pixel glyph at 2x is not the same bitmap as a
// 26-pixel glyph at 1x: the hinting and rounding differ, and reusing one for
// the other is exactly how text goes blurry on a Retina display.
Atlas :: struct {
	pixel_height: f32,
	scale_factor: f32,
	glyphs:       [GLYPH_COUNT]Glyph,
	ascent:       f32,
	descent:      f32,
	line_gap:     f32,
	pixels:       []u8,
	texture:      wgpu.Texture,
	view:         wgpu.TextureView,
	// Cost of rasterizing and uploading, for the cache-miss budget.
	build_ms: f64,
}

Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

SHADER :: `
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@group(0) @binding(0) var atlas_texture: texture_2d<f32>;
@group(0) @binding(1) var atlas_sampler: sampler;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = vec4<f32>(in.position, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // The atlas stores coverage in one channel. Multiplying it into alpha
    // keeps the glyph's colour flat and its edges antialiased.
    let coverage = textureSample(atlas_texture, atlas_sampler, in.uv).r;
    return vec4<f32>(in.color.rgb, in.color.a * coverage);
}
`

State :: struct {
	window:   ^sdl.Window,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	pipeline: wgpu.RenderPipeline,
	config:   wgpu.SurfaceConfiguration,
	sampler:  wgpu.Sampler,
	bind_layout: wgpu.BindGroupLayout,

	font_data: []u8,
	font:      stbtt.fontinfo,

	// Cache keyed by (pixel height, scale factor). A real renderer would key
	// by font too; the spike loads one face.
	atlases:    map[u64]^Atlas,
	bind_groups: map[u64]wgpu.BindGroup,

	vertex_buffer:   wgpu.Buffer,
	vertex_capacity: int,
	vertices:        [dynamic]Vertex,

	scale_factor: f32,
	width:        f32,
	height:       f32,
}

main :: proc() {
	frames := 0
	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		if arguments[index] == "--frames" {
			index += 1
			if index < len(arguments) {
				frames = parse_int(arguments[index])
			}
		}
	}

	state: State
	if !init(&state) {
		fmt.eprintln("spike: initialization failed")
		os.exit(1)
	}
	defer shutdown(&state)

	report_environment(&state)
	measure_atlas_costs(&state)
	verify_rasterization(&state)
	run(&state, frames)
}

@(private)
parse_int :: proc(text: string) -> int {
	value := 0
	for c in text {
		if c < '0' || c > '9' {
			return value
		}
		value = value * 10 + int(c - '0')
	}
	return value
}

init :: proc(state: ^State) -> bool {
	data, read_err := os.read_entire_file_from_path(FONT_PATH, context.allocator)
	if read_err != nil {
		fmt.eprintfln("spike: could not read %s", FONT_PATH)
		return false
	}
	state.font_data = data

	// A .ttc collection needs an explicit face offset; offset zero is only
	// correct for a single-face .ttf. GetFontOffsetForIndex handles both.
	offset := stbtt.GetFontOffsetForIndex(raw_data(state.font_data), 0)
	if offset < 0 {
		fmt.eprintln("spike: font contains no usable face")
		return false
	}
	if !stbtt.InitFont(&state.font, raw_data(state.font_data), offset) {
		fmt.eprintln("spike: stbtt.InitFont failed")
		return false
	}

	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("spike: SDL_Init failed: %s", sdl.GetError())
		return false
	}

	state.window = sdl.CreateWindow(
		"Norn text spike",
		1280,
		720,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if state.window == nil {
		fmt.eprintfln("spike: CreateWindow failed: %s", sdl.GetError())
		return false
	}

	state.instance = wgpu.CreateInstance(nil)
	state.surface = sdl3glue.GetSurface(state.instance, state.window)
	if state.surface == nil {
		fmt.eprintln("spike: could not create a WGPU surface")
		return false
	}

	wgpu.InstanceRequestAdapter(
		state.instance,
		&wgpu.RequestAdapterOptions{compatibleSurface = state.surface},
		{callback = on_adapter, userdata1 = state},
	)
	if state.adapter == nil {
		fmt.eprintln("spike: no compatible GPU adapter")
		return false
	}

	wgpu.AdapterRequestDevice(state.adapter, nil, {callback = on_device, userdata1 = state})
	if state.device == nil {
		fmt.eprintln("spike: could not create a GPU device")
		return false
	}
	state.queue = wgpu.DeviceGetQueue(state.device)

	update_metrics(state)

	capabilities, status := wgpu.SurfaceGetCapabilities(state.surface, state.adapter)
	if status != .Success {
		return false
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)

	state.config = wgpu.SurfaceConfiguration {
		device      = state.device,
		format      = capabilities.formats[0],
		usage       = {.RenderAttachment},
		width       = u32(state.width),
		height      = u32(state.height),
		presentMode = .Fifo,
		alphaMode   = .Opaque,
	}
	wgpu.SurfaceConfigure(state.surface, &state.config)

	state.atlases = make(map[u64]^Atlas)
	state.bind_groups = make(map[u64]wgpu.BindGroup)
	state.vertices = make([dynamic]Vertex, 0, 8192)

	return create_pipeline(state, capabilities.formats[0])
}

@(private)
on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: string,
	userdata1, userdata2: rawptr,
) {
	if status == .Success {
		(cast(^State)userdata1).adapter = adapter
	}
}

@(private)
on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: string,
	userdata1, userdata2: rawptr,
) {
	if status == .Success {
		(cast(^State)userdata1).device = device
	}
}

update_metrics :: proc(state: ^State) {
	pixel_width, pixel_height: i32
	sdl.GetWindowSizeInPixels(state.window, &pixel_width, &pixel_height)
	logical_width, _: i32
	sdl.GetWindowSize(state.window, &logical_width, nil)

	state.width = f32(pixel_width)
	state.height = f32(pixel_height)
	state.scale_factor = f32(pixel_width) / f32(max(logical_width, 1))
}

create_pipeline :: proc(state: ^State, format: wgpu.TextureFormat) -> bool {
	module := wgpu.DeviceCreateShaderModule(
		state.device,
		&wgpu.ShaderModuleDescriptor {
			nextInChain = &wgpu.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = SHADER,
			},
		},
	)
	if module == nil {
		fmt.eprintln("spike: shader compilation failed")
		return false
	}
	defer wgpu.ShaderModuleRelease(module)

	// Linear filtering, because the atlas is sampled at exactly 1:1 when the
	// scale factor matches. Nearest would alias on any fractional offset.
	state.sampler = wgpu.DeviceCreateSampler(
		state.device,
		&wgpu.SamplerDescriptor {
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = .Linear,
			minFilter = .Linear,
			mipmapFilter = .Nearest,
			maxAnisotropy = 1,
		},
	)

	entries := []wgpu.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	state.bind_layout = wgpu.DeviceCreateBindGroupLayout(
		state.device,
		&wgpu.BindGroupLayoutDescriptor{entryCount = len(entries), entries = raw_data(entries)},
	)

	layout := wgpu.DeviceCreatePipelineLayout(
		state.device,
		&wgpu.PipelineLayoutDescriptor {
			bindGroupLayoutCount = 1,
			bindGroupLayouts = &state.bind_layout,
		},
	)
	defer wgpu.PipelineLayoutRelease(layout)

	attributes := []wgpu.VertexAttribute {
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x2, offset = 8, shaderLocation = 1},
		{format = .Float32x4, offset = 16, shaderLocation = 2},
	}
	buffer_layout := wgpu.VertexBufferLayout {
		arrayStride = size_of(Vertex),
		stepMode = .Vertex,
		attributeCount = len(attributes),
		attributes = raw_data(attributes),
	}

	// Alpha blending: glyph coverage composites over whatever is behind it.
	blend := wgpu.BlendState {
		color = {srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha, operation = .Add},
		alpha = {srcFactor = .One, dstFactor = .OneMinusSrcAlpha, operation = .Add},
	}

	state.pipeline = wgpu.DeviceCreateRenderPipeline(
		state.device,
		&wgpu.RenderPipelineDescriptor {
			layout = layout,
			vertex = {
				module = module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &buffer_layout,
			},
			fragment = &wgpu.FragmentState {
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = format,
					blend = &blend,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = ~u32(0)},
		},
	)
	return state.pipeline != nil
}

// atlas_key combines the cache dimensions docs/07 names.
atlas_key :: proc "contextless" (pixel_height: f32, scale_factor: f32) -> u64 {
	// Quantized to hundredths so floating-point noise in a scale factor does
	// not produce a cache miss for a visually identical atlas.
	height := u64(pixel_height * 100)
	scale := u64(scale_factor * 100)
	return height << 32 | scale
}

// get_atlas returns a cached atlas, building it on first use.
//
// docs/07: the glyph atlas is generated lazily and cached by font, size, and
// scale factor. The build cost is recorded so the cache-miss budget can be
// checked against a real number.
get_atlas :: proc(state: ^State, pixel_height: f32) -> ^Atlas {
	key := atlas_key(pixel_height, state.scale_factor)
	if existing, found := state.atlases[key]; found {
		return existing
	}

	start := time.tick_now()

	atlas := new(Atlas)
	atlas.pixel_height = pixel_height
	atlas.scale_factor = state.scale_factor

	// Rasterize at the device pixel size, not the logical size. This is what
	// makes text crisp on a Retina display: a 13-point glyph on a 2x display
	// is rasterized at 26 device pixels and sampled 1:1.
	device_height := pixel_height * state.scale_factor
	scale := stbtt.ScaleForPixelHeight(&state.font, device_height)

	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&state.font, &ascent, &descent, &line_gap)
	atlas.ascent = f32(ascent) * scale
	atlas.descent = f32(descent) * scale
	atlas.line_gap = f32(line_gap) * scale

	atlas.pixels = make([]u8, ATLAS_SIZE * ATLAS_SIZE)

	// Simple shelf packing. stb_rect_pack would do better, but the spike is
	// measuring rasterization cost rather than packing efficiency.
	pen_x := 1
	pen_y := 1
	row_height := 0

	for index in 0 ..< GLYPH_COUNT {
		codepoint := rune(FIRST_GLYPH + index)

		width, height, offset_x, offset_y: i32
		bitmap := stbtt.GetCodepointBitmap(
			&state.font,
			scale,
			scale,
			codepoint,
			&width,
			&height,
			&offset_x,
			&offset_y,
		)

		advance, bearing: i32
		stbtt.GetCodepointHMetrics(&state.font, codepoint, &advance, &bearing)

		if pen_x + int(width) + 1 >= ATLAS_SIZE {
			pen_x = 1
			pen_y += row_height + 1
			row_height = 0
		}
		if int(height) > row_height {
			row_height = int(height)
		}
		if pen_y + int(height) + 1 >= ATLAS_SIZE {
			// The spike's glyph set always fits; a real atlas would evict or
			// allocate a second page here.
			fmt.eprintln("spike: atlas overflow")
			break
		}

		if bitmap != nil {
			for row in 0 ..< int(height) {
				source := bitmap[row * int(width):]
				destination := atlas.pixels[(pen_y + row) * ATLAS_SIZE + pen_x:]
				copy(destination[:width], source[:width])
			}
			stbtt.FreeBitmap(bitmap, nil)
		}

		atlas.glyphs[index] = Glyph {
			x0 = u16(pen_x),
			y0 = u16(pen_y),
			x1 = u16(pen_x + int(width)),
			y1 = u16(pen_y + int(height)),
			offset_x = f32(offset_x),
			offset_y = f32(offset_y),
			advance = f32(advance) * scale,
		}

		pen_x += int(width) + 1
	}

	atlas.texture = wgpu.DeviceCreateTexture(
		state.device,
		&wgpu.TextureDescriptor {
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {ATLAS_SIZE, ATLAS_SIZE, 1},
			format = .R8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	wgpu.QueueWriteTexture(
		state.queue,
		&wgpu.TexelCopyTextureInfo{texture = atlas.texture, mipLevel = 0, aspect = .All},
		raw_data(atlas.pixels),
		uint(len(atlas.pixels)),
		&wgpu.TexelCopyBufferLayout{bytesPerRow = ATLAS_SIZE, rowsPerImage = ATLAS_SIZE},
		&wgpu.Extent3D{ATLAS_SIZE, ATLAS_SIZE, 1},
	)
	atlas.view = wgpu.TextureCreateView(atlas.texture, nil)

	bind_entries := []wgpu.BindGroupEntry {
		{binding = 0, textureView = atlas.view},
		{binding = 1, sampler = state.sampler},
	}
	state.bind_groups[key] = wgpu.DeviceCreateBindGroup(
		state.device,
		&wgpu.BindGroupDescriptor {
			layout = state.bind_layout,
			entryCount = len(bind_entries),
			entries = raw_data(bind_entries),
		},
	)

	atlas.build_ms = time.duration_milliseconds(time.tick_since(start))
	state.atlases[key] = atlas
	return atlas
}

// draw_text appends vertices for a string at a pixel position.
//
// Positions are device pixels with the origin at the top left, converted to
// clip space at the end. Hit testing would use the same transform, which is
// what docs/07 requires to avoid selection drift.
draw_text :: proc(
	state: ^State,
	atlas: ^Atlas,
	text: string,
	x: f32,
	y: f32,
	color: [4]f32,
) -> f32 {
	pen_x := x
	baseline := y + atlas.ascent

	for index in 0 ..< len(text) {
		c := text[index]
		if c < FIRST_GLYPH || c >= FIRST_GLYPH + GLYPH_COUNT {
			// Outside the spike's glyph set. A real renderer would populate
			// the atlas lazily for this codepoint.
			pen_x += atlas.glyphs[0].advance
			continue
		}
		glyph := atlas.glyphs[c - FIRST_GLYPH]

		width := f32(glyph.x1 - glyph.x0)
		height := f32(glyph.y1 - glyph.y0)
		if width > 0 && height > 0 {
			// Snapping the pen to a whole pixel keeps stems aligned to the
			// pixel grid. Without it, text at fractional offsets goes soft.
			left := f32(int(pen_x + glyph.offset_x + 0.5))
			top := baseline + glyph.offset_y

			u0 := f32(glyph.x0) / ATLAS_SIZE
			v0 := f32(glyph.y0) / ATLAS_SIZE
			u1 := f32(glyph.x1) / ATLAS_SIZE
			v1 := f32(glyph.y1) / ATLAS_SIZE

			push_quad(state, left, top, width, height, u0, v0, u1, v1, color)
		}
		pen_x += glyph.advance
	}
	return pen_x - x
}

@(private)
push_quad :: proc(
	state: ^State,
	x, y, width, height: f32,
	u0, v0, u1, v1: f32,
	color: [4]f32,
) {
	to_clip :: proc(state: ^State, x, y: f32) -> [2]f32 {
		return {x / state.width * 2.0 - 1.0, 1.0 - y / state.height * 2.0}
	}

	top_left := to_clip(state, x, y)
	bottom_right := to_clip(state, x + width, y + height)

	a := Vertex{{top_left.x, top_left.y}, {u0, v0}, color}
	b := Vertex{{bottom_right.x, top_left.y}, {u1, v0}, color}
	c := Vertex{{top_left.x, bottom_right.y}, {u0, v1}, color}
	d := Vertex{{bottom_right.x, bottom_right.y}, {u1, v1}, color}

	append(&state.vertices, a, b, c, b, d, c)
}

// dump_glyph prints one rasterized glyph as text.
//
// The measurements above prove the code runs; they say nothing about whether
// the glyphs are correct. Printing coverage makes a wrong scale, a flipped
// axis, or an empty bitmap immediately visible without a screenshot.
dump_glyph :: proc(state: ^State, atlas: ^Atlas, codepoint: rune) {
	index := int(codepoint) - FIRST_GLYPH
	if index < 0 || index >= GLYPH_COUNT {
		return
	}
	glyph := atlas.glyphs[index]
	width := int(glyph.x1 - glyph.x0)
	height := int(glyph.y1 - glyph.y0)

	fmt.printfln("glyph %q at %.0f px (%dx%d, advance %.1f):",
		codepoint, f64(atlas.pixel_height * atlas.scale_factor), width, height, f64(glyph.advance))

	shades := [?]u8{' ', '.', ':', '-', '=', '+', '*', '#', '%', '@'}
	for row in 0 ..< height {
		line: [128]u8
		count := 0
		for column in 0 ..< width {
			if count >= len(line) {
				break
			}
			coverage := atlas.pixels[(int(glyph.y0) + row) * ATLAS_SIZE + int(glyph.x0) + column]
			line[count] = shades[int(coverage) * (len(shades) - 1) / 255]
			count += 1
		}
		fmt.printfln("  |%s|", string(line[:count]))
	}
	fmt.println()
}

// measure_atlas_costs reports the cache-miss cost for a range of sizes.
measure_atlas_costs :: proc(state: ^State) {
	fmt.println("=== atlas build cost (cache miss) ===")
	fmt.printfln("%-8s %-10s %-12s", "size", "device px", "build")

	sizes := []f32{11, 12, 13, 14, 16, 18, 24}
	worst := 0.0
	for size in sizes {
		atlas := get_atlas(state, size)
		if atlas.build_ms > worst {
			worst = atlas.build_ms
		}
		// Numbers are formatted separately and padded as strings: Odin's
		// left-align flag pads numeric verbs with zeros on the right.
		fmt.printfln(
			"%-8s %-10s %s ms",
			fmt.tprintf("%.0f", f64(size)),
			fmt.tprintf("%.0f", f64(size * state.scale_factor)),
			fmt.tprintf("%.3f", atlas.build_ms),
		)
	}

	// docs/07: no frame over 50 ms on a glyph-cache miss batch.
	verdict := "within budget" if worst < 50.0 else "OVER BUDGET"
	fmt.printfln("\nworst single atlas: %.3f ms  (50 ms budget: %s)", worst, verdict)
	fmt.println()
}

// verify_rasterization shows that glyphs are actually being produced.
verify_rasterization :: proc(state: ^State) {
	fmt.println("=== rasterization check ===")
	atlas := get_atlas(state, 13)
	dump_glyph(state, atlas, 'A')
	dump_glyph(state, atlas, 'g')

	// Metrics sanity: a monospace face must advance identically for every
	// glyph, and ascent must exceed descent.
	reference := atlas.glyphs['M' - FIRST_GLYPH].advance
	uniform := true
	for index in 0 ..< GLYPH_COUNT {
		if atlas.glyphs[index].advance != reference {
			uniform = false
			break
		}
	}
	fmt.printfln("monospace advance uniform: %v (%.2f px)", uniform, f64(reference))
	fmt.printfln("ascent %.2f, descent %.2f, line gap %.2f",
		f64(atlas.ascent), f64(atlas.descent), f64(atlas.line_gap))
	fmt.println()

	compare_scale_factors(state)
}

// compare_scale_factors shows why the cache key includes scale.
//
// docs/07 keys the atlas by font, size, and scale factor. If scale were
// omitted, a 13-point atlas built for a 1x display would be reused on a 2x
// one and upscaled, which is what blurry text on a Retina display looks like.
// This prints both to show they are different rasterizations, not the same
// bitmap at two sizes.
compare_scale_factors :: proc(state: ^State) {
	fmt.println("=== scale factor handling ===")

	saved := state.scale_factor
	defer state.scale_factor = saved

	fmt.printfln("%-8s %-12s %-12s %-10s", "scale", "device px", "cell width", "atlas key")
	for scale in ([]f32{1.0, 1.5, 2.0}) {
		state.scale_factor = scale
		atlas := get_atlas(state, 13)
		width := atlas.glyphs['M' - FIRST_GLYPH].x1 - atlas.glyphs['M' - FIRST_GLYPH].x0
		fmt.printfln(
			"%-8s %-12s %-12s %d",
			fmt.tprintf("%.1fx", f64(scale)),
			fmt.tprintf("%.0f", f64(13 * scale)),
			fmt.tprintf("%d px", width),
			atlas_key(13, scale),
		)
	}

	// Each scale must have produced its own atlas rather than reusing one.
	fmt.printfln("distinct atlases cached: %d", len(state.atlases))
	fmt.println()
}

Metrics :: struct {
	frames:        int,
	measured:      int,
	total_build_ms: f64,
	worst_build_ms: f64,
	glyphs:        int,
}

WARMUP_FRAMES :: 10

run :: proc(state: ^State, frame_limit: int) {
	metrics: Metrics
	running := true

	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}
			case .WINDOW_PIXEL_SIZE_CHANGED:
				resize(state)
			}
		}

		start := time.tick_now()
		glyphs := build_scene(state)
		build_ms := time.duration_milliseconds(time.tick_since(start))

		render(state)

		metrics.frames += 1
		if metrics.frames > WARMUP_FRAMES {
			metrics.measured += 1
			metrics.total_build_ms += build_ms
			metrics.glyphs = glyphs
			if build_ms > metrics.worst_build_ms {
				metrics.worst_build_ms = build_ms
			}
		}

		if frame_limit > 0 && metrics.frames >= frame_limit {
			running = false
		}
	}

	report_metrics(&metrics)
}

// build_scene lays out a screenful of text resembling a diff panel.
build_scene :: proc(state: ^State) -> int {
	clear(&state.vertices)

	atlas := get_atlas(state, 13)
	line_height := atlas.ascent - atlas.descent + atlas.line_gap

	foreground := [4]f32{0.90, 0.91, 0.93, 1.0}
	added := [4]f32{0.45, 0.78, 0.55, 1.0}
	removed := [4]f32{0.88, 0.44, 0.44, 1.0}

	samples := []string {
		"  package model",
		"- string_intern :: proc(table: ^String_Table, value: string) -> String_Id {",
		"+ string_intern :: proc(table: ^String_Table, value: string) -> (String_Id, bool) {",
		"      if len(value) == 0 {",
		"          return EMPTY_STRING, true",
		"      }",
		"      key := string_hash(value)",
		"      if bucket, found := table.buckets[key]; found {",
		"          for candidate in bucket {",
		"              existing, got := string_get(table, candidate)",
		"              if got && existing == value {",
		"                  return candidate, true",
		"              }",
		"          }",
		"      }",
	}

	glyphs := 0
	y := f32(16)
	for y < state.height - line_height {
		for line in samples {
			if y >= state.height - line_height {
				break
			}
			color := foreground
			if len(line) > 0 {
				switch line[0] {
				case '+': color = added
				case '-': color = removed
				}
			}
			draw_text(state, atlas, line, 16, y, color)
			glyphs += len(line)
			y += line_height
		}
	}
	return glyphs
}

resize :: proc(state: ^State) {
	update_metrics(state)
	if state.width <= 0 || state.height <= 0 {
		return
	}
	state.config.width = u32(state.width)
	state.config.height = u32(state.height)
	wgpu.SurfaceConfigure(state.surface, &state.config)
}

ensure_capacity :: proc(state: ^State, count: int) {
	if count <= state.vertex_capacity && state.vertex_buffer != nil {
		return
	}
	if state.vertex_buffer != nil {
		wgpu.BufferRelease(state.vertex_buffer)
	}
	capacity := max(count * 2, 8192)
	state.vertex_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&wgpu.BufferDescriptor {
			usage = {.Vertex, .CopyDst},
			size = u64(capacity * size_of(Vertex)),
		},
	)
	state.vertex_capacity = capacity
}

render :: proc(state: ^State) {
	surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Occluded:
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		return
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		resize(state)
		return
	case .Error:
		return
	}
	defer wgpu.TextureRelease(surface_texture.texture)

	view := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(view)

	count := len(state.vertices)
	if count > 0 {
		ensure_capacity(state, count)
		wgpu.QueueWriteBuffer(
			state.queue,
			state.vertex_buffer,
			0,
			raw_data(state.vertices),
			uint(count * size_of(Vertex)),
		)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(state.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&wgpu.RenderPassDescriptor {
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = view,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = {0.09, 0.10, 0.12, 1.0},
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			},
		},
	)

	if count > 0 {
		key := atlas_key(13, state.scale_factor)
		if bind_group, found := state.bind_groups[key]; found {
			wgpu.RenderPassEncoderSetPipeline(pass, state.pipeline)
			wgpu.RenderPassEncoderSetBindGroup(pass, 0, bind_group)
			wgpu.RenderPassEncoderSetVertexBuffer(
				pass,
				0,
				state.vertex_buffer,
				0,
				u64(count * size_of(Vertex)),
			)
			// Every glyph on screen in one draw call, which is the point of
			// an atlas.
			wgpu.RenderPassEncoderDraw(pass, u32(count), 1, 0, 0)
		}
	}

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	command := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(command)
	wgpu.QueueSubmit(state.queue, {command})
	wgpu.SurfacePresent(state.surface)
}

report_environment :: proc(state: ^State) {
	info, _ := wgpu.AdapterGetInfo(state.adapter)
	defer wgpu.AdapterInfoFreeMembers(info)

	logical_width, logical_height: i32
	sdl.GetWindowSize(state.window, &logical_width, &logical_height)

	fmt.println("=== environment ===")
	fmt.printfln("adapter:   %s (%v)", info.device, info.backendType)
	fmt.printfln("font:      %s", FONT_PATH)
	fmt.printfln(
		"window:    %dx%d logical, %.0fx%.0f pixels (scale %.1fx)",
		logical_width,
		logical_height,
		f64(state.width),
		f64(state.height),
		f64(state.scale_factor),
	)
	fmt.println()
}

report_metrics :: proc(metrics: ^Metrics) {
	if metrics.measured == 0 {
		return
	}
	average := metrics.total_build_ms / f64(metrics.measured)

	fmt.println("=== steady state (atlas cached) ===")
	fmt.printfln("frames:          %d (%d measured)", metrics.frames, metrics.measured)
	fmt.printfln("glyphs on screen: %d", metrics.glyphs)
	fmt.printfln("mean layout CPU: %.3f ms", average)
	fmt.printfln("worst layout:    %.3f ms", metrics.worst_build_ms)

	verdict := "within budget" if average < 8.0 else "OVER BUDGET"
	fmt.printfln("budget (8 ms):   %s", verdict)
}

shutdown :: proc(state: ^State) {
	for _, bind_group in state.bind_groups {
		wgpu.BindGroupRelease(bind_group)
	}
	delete(state.bind_groups)

	for _, atlas in state.atlases {
		wgpu.TextureViewRelease(atlas.view)
		wgpu.TextureRelease(atlas.texture)
		delete(atlas.pixels)
		free(atlas)
	}
	delete(state.atlases)

	if state.vertex_buffer != nil {
		wgpu.BufferRelease(state.vertex_buffer)
	}
	if state.bind_layout != nil {
		wgpu.BindGroupLayoutRelease(state.bind_layout)
	}
	if state.sampler != nil {
		wgpu.SamplerRelease(state.sampler)
	}
	if state.pipeline != nil {
		wgpu.RenderPipelineRelease(state.pipeline)
	}
	if state.queue != nil {
		wgpu.QueueRelease(state.queue)
	}
	if state.device != nil {
		wgpu.DeviceRelease(state.device)
	}
	if state.adapter != nil {
		wgpu.AdapterRelease(state.adapter)
	}
	if state.surface != nil {
		wgpu.SurfaceRelease(state.surface)
	}
	if state.instance != nil {
		wgpu.InstanceRelease(state.instance)
	}
	if state.window != nil {
		sdl.DestroyWindow(state.window)
	}
	delete(state.vertices)
	delete(state.font_data)
	sdl.Quit()
}
