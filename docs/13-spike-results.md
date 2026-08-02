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

## Renderer backend

**Verdict: the batched renderer works end to end on Metal.**

`scripts/norn.sh spike backend` builds a timeline frame from a 20,000-event
trace, sweeps the viewport, and submits through `src/render`. Both pipelines
compile on the real device.

| Measurement | Value |
| --- | ---: |
| Commands per frame | 7,018 |
| Draw calls | 4 |
| Peak resident set, 600 frames | 140 MiB |

7,018 commands collapsing to 4 draw calls is the batching working: the frame
changes pipeline or clip only four times.

The instance ring grew from 12,288 to 42,106 instances and then stopped, which
is the intended amortization — it doubles on demand rather than reallocating
per frame, and settles once it fits the workload.

Frame wall time tracks the 120 Hz refresh under `Fifo`, as with the other
spikes. The CPU-side cost of query, layout, draw-list construction and batching
was measured separately at 0.014 ms for a typical zoom and 2.4 ms with all
100,000 reference events visible.

### Carried into the renderer

The text spike's approach is now `src/render/font.odin`, with the atlas cache
keyed by font, size, and scale as measured. Wiring it into the timeline
surfaced a defect the spike could not: the panel sized its label box from an
unscaled constant while the atlas was rasterized at the display scale, so the
longer lane names were silently truncated on every high-DPI display. The box
is now derived from the viewport origin, which the caller has already scaled,
and a test asserts every label survives at 1x, 1.5x, and 2x.

## Graph layout cost

The repository map's force-directed layout runs once when a trace opens, not
per frame. Release build, at the node budget from docs/07:

| Nodes | Layout |
| ---: | ---: |
| 50 | 1.0 ms |
| 100 | 4.2 ms |
| 200 | 16.8 ms |
| 300 | 38.1 ms |

The O(n²) repulsion is what drives the curve. 38 ms once per trace is
acceptable where 38 ms per frame would not be, which is why the layout is built
at open time and the positions are then immutable — the arrangement docs/07
describes as "publishes immutable position buffers".

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

## Import measurements

Machine: Apple M1 Pro, macOS 15 (Darwin 25.5.0). Odin `dev-2026-07:819fdc7a8`,
debug build. Fixtures generated by `scripts/norn.sh fixture <tier>`. Per docs/09
a single local number is not a portable promise; these are recorded so a later
regression is visible as a change rather than argued about from memory.

| Tier | Records | Events | Source | Trace | Import | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| tiny | 40 | 42 | 5 KB | 12 KB | <0.01 s | 4 MB |
| representative | 2,000 | 2,317 | 252 KB | 411 KB | 0.11 s | 13 MB |
| reference | 60,000 | 69,400 | 7.4 MB | 11.8 MB | 2.85 s | 99 MB |
| stress | 600,000 | 693,635 | 73.8 MB | 116.2 MB | 28.7 s | 667 MB |

Every mutation in every tier replays verified: the generator emits truthful
`before` content, so the hash chains hold end to end.

### Streaming is bounded, and was not at first

docs/05 requires that the parser "must not load the entire source log into
memory". The first implementation satisfied this only in shape: each record was
parsed independently, but nothing released the memory, so parse-only peak grew
with the file — 93 MB for the 7.4 MB reference tier.

Parse-only peak after resetting a per-record arena:

| Tier | Source | Peak RSS | Overhead |
| --- | ---: | ---: | ---: |
| representative | 252 KB | 9.8 MB | ~9 MB |
| reference | 7.4 MB | 16.9 MB | ~9 MB |
| stress | 73.8 MB | 83.3 MB | ~9 MB |

Constant overhead across a 300× range in source size, which is what bounded
actually means. The remaining growth is the source buffer itself.

Two things this cost, worth remembering:

- The arena must be **private to the adapter**. Resetting
  `context.temp_allocator` reclaims memory the caller owns — and callers do
  allocate the source from it, which turned every test log into freed memory
  after its first record.
- A `map` key that points into parsed record memory dangles once that memory is
  reclaimed. Keys are cloned and owned separately, because `delete_key` does not
  free them.

Full-import peak still scales with the session, because the trace being built is
held until it is written. That is the accumulated product, not the parser.

## Replay seek and reconstruction

docs/00 budgets reconstructing any indexed text file at **under 100 ms p95**, and
docs/11 makes reference-fixture seek a Phase 2 exit criterion. Measured with
`scripts/norn.sh bench <trace.norn>`, release build, on the machine above.

Reference tier: 69,354 events, 7,162 mutations, 74 MB trace.

| Pattern | n | p50 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| forward step | 2,388 | 0.052 ms | 0.064 ms | 0.093 ms |
| backward step | 2,387 | 2.161 ms | 4.143 ms | 4.728 ms |
| random seek | 2,000 | 2.301 ms | 4.277 ms | 6.024 ms |
| end-to-end jump | 256 | 2.215 ms | 4.021 ms | 4.206 ms |
| **seek + resolve** | 2,000 | 2.240 ms | **4.278 ms** | 5.786 ms |
| resolve only | 2,000 | 0.004 ms | 0.006 ms | 0.019 ms |

Session setup — baseline, timeline, and snapshots — is 139 ms, paid once when a
trace opens rather than per seek.

**4.28 ms p95 against a 100 ms budget**, roughly 23x headroom. 1,998 of 2,000
resolves returned content, 17.4 MB in total, so the number reflects real
reconstruction rather than empty lookups.

Forward stepping is forty times cheaper than any other pattern because it
replays one mutation from where the engine already sits. Everything else pays a
snapshot restore plus up to `SNAPSHOT_INTERVAL` replays, which is what the
interval is tuned against — and why the three non-sequential patterns all land
within a millisecond of each other regardless of distance.

`resolve` on an already-positioned engine is effectively free. Reconstruction
cost is seeking, not reading.

### Two measurement traps this hit

- **Seek alone is not the budgeted operation.** The first version measured
  `seek` and reported 0.079 ms p95 — true, and irrelevant: seek only moves a
  path map. The budget is about producing file content, which is `seek` plus
  `resolve`. Measuring the wrong operation would have claimed a 1200x margin.
- **Fixture content has to be realistic.** With the generator's original 36-byte
  stub files the same benchmark reported 0.081 ms p95. Nothing was wrong with
  the harness; the input simply had no content to reconstruct. Generated files
  are now 200-600 lines, which moved the measurement by 50x.

Also hit, for the third time in this project: Odin pads numeric format verbs
with **zeros**, so `%-6d` printed a sample count of 2373 as "237300" and
`%8.3f` printed 0.041 as "0000.041". Every aligned numeric column must be
formatted to a string first.

## Hostile fixture results

docs/11 Phase 5 requires that "opening all hostile fixtures causes no execution,
repository writes, crashes, or unbounded allocation." The fixtures live in
`tests/fixtures/hostile` and run via `scripts/test-security.sh`, which is part
of `scripts/norn.sh test`.

Each fixture attacks one non-negotiable property from docs/08, and every check
is outcome-based: not "was validation called" but "did the damage happen" — no
sentinel file exists, the repository hash is unchanged, memory stayed bounded.
118 checks, all passing.

### One real crash, found on the first run

`encoding.jsonl` aborted the process with SIGTRAP:

```
core/encoding/json/parser.odin(507:10) Invalid slice indices 31:28 out of range 0..<28
```

Odin's JSON string decoder sizes its output buffer from the input length. An
invalid byte decodes to `RUNE_ERROR`, which re-encodes to **three** bytes, so a
single stray `0xFF` inside a string writes past the end of the buffer. This is
reachable from any hostile log — a denial of service, and a buffer overflow in a
parser handling untrusted input.

Fixed by validating UTF-8 at the trust boundary before the parser sees a record,
which docs/08 required anyway. Kept as a unit test as well as a fixture, so an
upstream repair cannot silently remove the protection.

### Two false positives in the checks themselves

Both worth recording, because both would have made the gate useless in opposite
directions:

- **Matching escaped content.** `grep "onload="` fires on `&lt;svg
  onload=...&gt;`, which is inert text and exactly what correct escaping
  produces. The check now looks for a real tag opening. A gate that fails when
  the product is behaving correctly gets disabled.
- **Matching the defence as the attack.** Including `meta` in the active-element
  list flagged the report's own CSP declaration.

### One check that could not fail

The path-escape assertion searched `inspect --json` output for `/etc/passwd`.
That command prints counts and metadata, never the path table, so a retained
escaping path would never have appeared. Disabling path normalization confirmed
it: the trace contained `/etc/passwd` and the gate still passed. It now searches
the trace bytes, and fails as it should.

This is the general lesson from the exercise: every security check was
deliberately broken to confirm it fails. Three of them didn't at first.

### Where the defence already was

Two routes could put ill-formed text into a shared export: raw invalid bytes in
a source log, and escaped-but-invalid sequences such as a lone `\ud800`. The
first is the crash above, now refused at import. The second turns out to be
handled before it becomes a problem — Odin's JSON parser normalizes a lone
surrogate to U+FFFD during parsing, so those bytes never reach the string table.
The export layer's `sanitize_text` is a third defence behind both.

Disabling `sanitize_text` therefore did not fail the suite, which is the honest
result rather than a gap: nothing reaches it. The check asserts the property a
user depends on — that a shared report parses — rather than any one of the three
mechanisms, because all three sit in code that could change.
