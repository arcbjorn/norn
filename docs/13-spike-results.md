# Phase-zero spike results

Measurements from the phase-zero technical spikes. docs/11 states that spike
code may be discarded but its measurements and decisions remain; this document
is that record.

## Graphics stack: SDL3 + WGPU on macOS

**Verdict: decision 002 is confirmed. The provisional status is lifted.**

The pairing works on macOS with no workarounds in Norn's own code. The only
friction is in obtaining the wgpu-native binary, described under dependency
findings below.

### Environment

| Item | Value |
| --- | --- |
| Date | 2026-08-02 |
| Machine | Apple M1 Pro |
| OS | macOS (Darwin 25.5.0) |
| Odin | `dev-2026-07:819fdc7a8` |
| SDL3 | 3.4.12 (Homebrew) |
| wgpu-native | 29.0.1.1 (upstream release binary) |
| Backend selected | Metal |
| Surface format | `BGRA8UnormSrgb` |
| Display | 1280x720 logical, 2560x1440 pixels (2.0x scale), 120 Hz |

### What the spike did

Opened an SDL3 window, obtained a WGPU surface through `vendor:wgpu/sdl3glue`,
compiled a WGSL shader, and rendered one instanced quad per timeline event with
a single draw call per frame. Pan and zoom were driven through the same
viewport transform used for drawing.

### Frame cost

Per-frame CPU time to build the visible instance set, excluding GPU acquire and
present. Measured after ten warm-up frames.

Release build (`-o:speed`), which is what the budget applies to:

| Events visible | Mean | Worst |
| ---: | ---: | ---: |
| 100,000 | 0.31 ms | 0.93 ms |
| 1,000,000 | 3.09 ms | 7.98 ms |

Debug build, for comparison:

| Events visible | Mean | Worst |
| ---: | ---: | ---: |
| 1,000 | 0.020 ms | 0.028 ms |
| 10,000 | 0.186 ms | 0.268 ms |
| 100,000 | 1.79 ms | 2.78 ms |
| 1,000,000 | 18.24 ms | 25.46 ms |

Scaling is linear in both: roughly 3 ns per instance optimized, 18 ns in debug.
The 5.7x gap matters when interpreting any future measurement — a debug figure
near the budget is not a failing one.

The reference workload of 100,000 events sits at **0.31 ms against the 8 ms
budget** in docs/07, with every event visible at once, which is the worst case
for virtualization since zooming in only reduces the count.

A 3,600-frame sustained debug run held 1.77 ms mean with a peak resident set of
**110 MiB**, against the 1 GiB budget in docs/00. No growth was observed.

### Measuring frame time correctly

An early version of this spike reported "8.4 ms, over budget" at every event
count from 1,000 to 100,000. A cost that does not vary with workload is not a
workload cost: under `Fifo` present mode the acquire and present calls block
until the display's next refresh, so the figure was measuring a 120 Hz monitor.

The budget in docs/07 is Norn's own per-frame CPU work, so that is what the
table above reports. Wall-clock frame time is recorded separately by the spike
and tracks the refresh interval, as it should.

### The million-event case

One million visible events costs 3.09 ms optimized, still inside the budget,
though the 7.98 ms worst frame leaves no headroom. In debug it is 18.24 ms.

Aggregation is therefore not required for correctness at this scale, but
docs/07 mandates it at distant zoom anyway, and the worst-frame figure shows
why: a single frame that misses the refresh interval is a visible stutter while
scrubbing. The measurement puts the aggregation threshold somewhere below a
million instances per frame rather than at it.

## Text rendering and glyph atlas

**Verdict: stb_truetype plus a GPU atlas meets the requirements. No further
spike is needed before building the UI.**

### What the spike did

Loaded a system monospace face with `vendor:stb/truetype`, rasterized printable
ASCII into a 1024x1024 R8 coverage texture, uploaded it once, and drew a
screenful of diff-shaped text as one draw call sampling that atlas.

### Frame cost

Release build. Layout means building the vertex buffer for every visible glyph
from a cached atlas, which is the steady-state cost.

| Measurement | Value | Budget |
| --- | ---: | ---: |
| Layout, 1,965 glyphs on screen | 0.022 ms mean, 0.042 ms worst | 8 ms |
| Atlas build, single size (cache miss) | 0.49-0.76 ms | 50 ms |
| Peak resident set, 3,600 frames | 110 MiB | 1 GiB |

The cache-miss budget in docs/07 has roughly seventy times the headroom needed
for one atlas, so a batch of several sizes appearing at once is still far
inside it.

### High-DPI behaviour

The atlas cache is keyed by size *and* scale factor, as docs/07 requires.
Rasterizing a 13-point face at three scales produces three distinct atlases:

| Scale | Device pixels | Cell width |
| --- | ---: | ---: |
| 1.0x | 13 | 7 px |
| 1.5x | 20 | 10 px |
| 2.0x | 26 | 12 px |

These are separate rasterizations, not one bitmap sampled at three sizes. That
distinction is the whole point of including scale in the key: reusing a 1x
atlas on a 2x display is what blurry Retina text is.

Glyph origins are snapped to whole device pixels when positioned, which keeps
stems on the pixel grid.

### Correctness

Measurements prove the code runs, not that it draws anything legible. The spike
therefore also dumps rasterized coverage as text, which shows correct shapes
with antialiased edges, a proper descender on `g`, and uniform advance across
the monospace face (13.65 px at 26 device pixels). Ascent 21.34, descent -4.66.

## Dependency findings

### wgpu-native is not vendored for macOS

Odin's `vendor:wgpu` ships a compiled library only for
`wgpu-windows-x86_64-msvc-release`. macOS and Linux builds must be supplied by
the project. The bindings expect them at
`vendor/wgpu/lib/wgpu-macos-<arch>-<type>/lib/`, where `<arch>` is `aarch64`
(not `arm64`).

This is a packaging obligation for Norn: a contributor cannot build the UI
after `brew install odin` alone.

### Homebrew's wgpu-native reports version 0.0.0.0

`brew install wgpu-native` yields a library whose `wgpuGetVersion()` returns
`0x00000000`, so Odin's binding refuses it with a version-mismatch panic even
though the formula is 29.0.1.1. The upstream release archive for the same
version returns `0x1D000101` and works.

**Consequence:** pin the upstream `wgpu-native` release binary rather than the
Homebrew package. The bootstrap script must fetch and place it, and the pinned
version must match `BINDINGS_VERSION` in the Odin release being used.

### Odin's stb libraries are not prebuilt

`vendor:stb/truetype` and `vendor:stb/rect_pack` fail to compile until the
vendored C sources are built:

```sh
make -C "$(odin root)/vendor/stb/src"
```

This produces universal binaries and takes a few seconds. Like the wgpu
situation, it writes into the Odin installation rather than the project tree,
so it must be redone after upgrading Odin. `scripts/bootstrap-graphics.sh`
handles both.

### Licensing

| Dependency | License | Distribution implication |
| --- | --- | --- |
| SDL3 3.4.12 | Zlib | Permissive; no attribution file required, one is courteous |
| wgpu-native 29.0.1.1 | Apache-2.0 / MIT | Attribution required in distributed binaries |
| stb_truetype | MIT / public domain | No obligation either way |
| Odin | BSD-3-Clause | Attribution required |

A shipped release must also decide whether to bundle a font or use system
faces. The spike reads `/System/Library/Fonts/SFNSMono.ttf`, which is
convenient but macOS-specific and not redistributable; Linux support will need
either a bundled open face or per-platform font discovery.

An eventual macOS release must ship a notices file covering wgpu-native and
Odin. Neither license is copyleft, so static linking is unproblematic.

### Linux feasibility

The same bindings expose a `wgpu-linux-<arch>-<type>` path and
`vendor:wgpu/sdl3glue` has a `glue_linux.odin`, so the arrangement is
structurally identical. wgpu-native selects Vulkan there. This was not tested;
the finding is only that nothing in the macOS path is macOS-specific beyond
which backend WGPU picks.

## Notes for the renderer

Observations from writing the spike that apply to the real renderer:

- Quad corners can be generated in the vertex shader from
  `@builtin(vertex_index)`, so no vertex buffer is needed at all — only the
  per-instance buffer.
- `Occluded` is a distinct surface status on macOS and yields no texture.
  Treating it as success crashes inside `TextureCreateView` with
  `invalid texture`. It must skip the frame.
- Zero-duration events need a minimum width of about one pixel or they become
  invisible and unclickable. Hit testing must use the same widened rectangle.
- A `.ttc` font collection needs `GetFontOffsetForIndex`; passing offset zero to
  `InitFont` is only correct for a single-face `.ttf`.
- Odin's `%-8.0f` pads numbers with **zeros on the right**, unlike C. Every
  left-aligned numeric column must be formatted to a string first. This
  produced garbage in two separate spikes before being noticed.
- First-frame cost is roughly 65 ms for shader compilation and pipeline
  creation. This is once per session, but a visible window should not appear
  before it completes.

## Open items not yet spiked

The remaining phase-zero items in docs/11 are untouched:

- the 30-minute stability run (only 30 seconds was measured, per spike);
- compression codec candidates for the trace format;
- memory-mapped columnar query performance.

None of these gate UI work. The codec items matter before the trace format is
declared stable; the long stability run matters before release.
