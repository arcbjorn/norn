# Engineering notes

Measurements, dependency findings, and the mistakes worth not repeating.
docs/11 states that spike code may be discarded but its measurements and
decisions remain; this is that record, extended as later work produced numbers
of its own.

Unless stated otherwise, all measurements share one environment:

| Item | Value |
| --- | --- |
| Machine | Apple M1 Pro, macOS (Darwin 25.5.0) |
| Odin | `dev-2026-07:819fdc7a8` |
| SDL3 | 3.4.12 (Homebrew) |
| wgpu-native | 29.0.1.1 (upstream release), Metal backend |
| Display | 1280x720 logical, 2560x1440 pixels (2.0x), 120 Hz |

docs/09: a single local number is not a portable promise. These exist so that a
later regression is visible as a change rather than argued from memory.

## Graphics stack

**Decision 002 is confirmed.** SDL3 and WGPU pair on macOS with no workarounds
in Norn's own code. The only friction is obtaining the wgpu-native binary.

Per-frame CPU time to build the visible instance set, excluding GPU acquire and
present, after ten warm-up frames. The 8 ms budget in docs/07 covers this work.

| Events visible | Release mean | Release worst | Debug mean |
| ---: | ---: | ---: | ---: |
| 100,000 | 0.31 ms | 0.93 ms | 1.79 ms |
| 1,000,000 | 3.09 ms | 7.98 ms | 18.24 ms |

Scaling is linear: roughly 3 ns per instance optimized, 18 ns in debug. The
5.7x gap matters when reading any debug figure — one near the budget is not a
failing one.

The reference workload of 100,000 events sits at **0.31 ms against 8 ms** with
every event visible at once, which is the worst case for virtualization. A
3,600-frame sustained run held 110 MiB peak against the 1 GiB budget in
docs/00, with no growth.

One million events still fits, but the 7.98 ms worst frame leaves no headroom.
docs/07 mandates aggregation at distant zoom regardless; this puts the
threshold somewhere below a million instances per frame rather than at it.

## Text rendering

stb_truetype rasterization into a GPU atlas, drawn through the same instanced
pipeline as timeline events. Release build.

| Measurement | Value | Budget |
| --- | ---: | ---: |
| Layout, 1,965 glyphs on screen | 0.022 ms mean, 0.042 ms worst | 8 ms |
| Atlas build (cache miss) | 0.49–0.76 ms | 50 ms |
| Peak resident set, 3,600 frames | 110 MiB | 1 GiB |

The cache is keyed by face, size, **and** scale, as docs/07 requires.
Rasterizing one 13-point face at 1.0x, 1.5x, and 2.0x produces three distinct
atlases at 13, 20, and 26 device pixels — separate rasterizations, not one
bitmap sampled three ways. That distinction is the whole point of the key:
reusing a 1x atlas on a 2x display is what blurry Retina text is. Glyph origins
snap to whole device pixels, which keeps stems on the grid.

Measurements prove the code runs, not that it draws anything legible, so the
spike also dumps rasterized coverage as text: correct shapes, antialiased
edges, a proper descender on `g`, uniform advance across the monospace face.

## Renderer backend

A timeline frame from a 20,000-event trace, swept and submitted through
`src/render`.

| Measurement | Value |
| --- | ---: |
| Commands per frame | 7,018 |
| Draw calls | 4 |
| Peak resident set, 600 frames | 140 MiB |

7,018 commands collapsing to 4 draw calls is the batching working: the frame
changes pipeline or clip only four times. The instance ring grew from 12,288 to
42,106 instances and stopped — it doubles on demand rather than reallocating per
frame, and settles once it fits the workload.

CPU-side query, layout, draw-list construction and batching cost 0.014 ms for a
typical zoom and 2.4 ms with all 100,000 reference events visible.

## Graph layout

The repository map's force-directed layout runs once when a trace opens, not per
frame. Release build, at the node budget from docs/07:

| Nodes | Layout |
| ---: | ---: |
| 50 | 1.0 ms |
| 100 | 4.2 ms |
| 200 | 16.8 ms |
| 300 | 38.1 ms |

O(n²) repulsion drives the curve. 38 ms once per trace is acceptable where 38 ms
per frame would not be, which is why positions are computed at open time and
then immutable — docs/07's "publishes immutable position buffers".

## Replay seek and reconstruction

docs/00 budgets reconstructing any indexed text file at **under 100 ms p95**.
Measured through `app.replay_session_init` and `replay.seek` — the same path the
viewer takes — on the reference tier of 69,354 events and 7,162 mutations.

| Pattern | p50 | p95 |
| --- | ---: | ---: |
| forward step | 0.052 ms | 0.064 ms |
| backward step | 2.161 ms | 4.143 ms |
| random seek | 2.301 ms | 4.277 ms |
| end-to-end jump | 2.215 ms | 4.021 ms |
| **seek + resolve** | 2.240 ms | **4.278 ms** |
| resolve only | 0.004 ms | 0.006 ms |

**4.28 ms p95 against 100 ms.** Session setup — baseline, timeline, snapshots —
is 139 ms, paid once when a trace opens.

Forward stepping is forty times cheaper because it replays one mutation from
where the engine already sits. Everything else pays a snapshot restore plus up
to `SNAPSHOT_INTERVAL` replays, which is why the three non-sequential patterns
land within a millisecond of each other regardless of distance. Reconstruction
cost is seeking, not reading.

Baseline digest verification hashes every baseline file on `engine_reset`, and
backward seeking resets often, so it looked like it might matter. With eight
captured files of roughly 400 lines, backward step p95 is 2.03 ms; snapshot
restores avoid most resets.

## Search

Linear scan, no index, on the reference tier.

| Query | Hits | p50 | p95 |
| --- | ---: | ---: | ---: |
| `engine` | 500 | 7.36 ms | 7.69 ms |
| `odin test` | 500 | 6.20 ms | 6.36 ms |
| `zzz-no-match` | 0 | 5.53 ms | 5.67 ms |
| `42` | 500 | 8.57 ms | 8.63 ms |

An index would have to be built on open, kept current, and stored in the
container. A scan comparing interned strings is already fast enough to run on
every keystroke.

## Import

| Tier | Records | Events | Source | Trace | Import | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| tiny | 40 | 42 | 5 KB | 12 KB | <0.01 s | 4 MB |
| representative | 2,000 | 2,317 | 252 KB | 411 KB | 0.11 s | 13 MB |
| reference | 60,000 | 69,400 | 7.4 MB | 11.8 MB | 2.85 s | 99 MB |
| stress | 600,000 | 693,635 | 73.8 MB | 116.2 MB | 28.7 s | 667 MB |

Every mutation in every tier replays verified.

Parse-only peak, which is what docs/05's streaming requirement governs:

| Tier | Source | Peak RSS | Overhead |
| --- | ---: | ---: | ---: |
| representative | 252 KB | 9.8 MB | ~9 MB |
| reference | 7.4 MB | 16.9 MB | ~9 MB |
| stress | 73.8 MB | 83.3 MB | ~9 MB |

Constant overhead across a 300x range in source size, which is what bounded
actually means. Full-import peak still scales with the session because the trace
being built is held until written — that is the accumulated product, not the
parser.

## Dependency findings

**wgpu-native is not vendored for macOS.** Odin's `vendor:wgpu` ships a compiled
library only for Windows. macOS and Linux builds must be supplied at
`vendor/wgpu/lib/wgpu-macos-<arch>-<type>/lib/`, where `<arch>` is `aarch64`,
not `arm64`.

**Homebrew's wgpu-native reports version 0.0.0.0.** `wgpuGetVersion()` returns
`0x00000000`, so Odin's binding refuses it with a version-mismatch panic even
though the formula is 29.0.1.1. The upstream release archive for the same
version returns `0x1D000101` and works. Pin the upstream binary.

**Odin's stb libraries are not prebuilt.** `vendor:stb/truetype` and `rect_pack`
fail to compile until `make -C "$(odin root)/vendor/stb/src"` runs. Like the
wgpu situation this writes into the Odin installation rather than the project
tree, so it must be redone after upgrading Odin.

`scripts/bootstrap-graphics.sh` handles both. A contributor cannot build the UI
after `brew install odin` alone.

| Dependency | License | Distribution implication |
| --- | --- | --- |
| SDL3 3.4.12 | Zlib | Permissive; attribution courteous |
| wgpu-native 29.0.1.1 | Apache-2.0 / MIT | Attribution required |
| stb_truetype | MIT / public domain | None |
| Odin | Zlib | Notice must be retained in source distributions |

Nothing is copyleft, so static linking is unproblematic. `NOTICE.md` carries
the required attributions and must ship with any binary release. A release and must decide whether to bundle a font: the spike reads
`/System/Library/Fonts/SFNSMono.ttf`, which is macOS-specific and not
redistributable.

Linux was not tested. The bindings expose a `wgpu-linux-<arch>-<type>` path and
`sdl3glue` has a `glue_linux.odin`, so the arrangement is structurally identical
with Vulkan selected instead of Metal.

## Renderer notes

- Quad corners generate in the vertex shader from `@builtin(vertex_index)`, so
  no vertex buffer is needed — only the per-instance buffer.
- `Occluded` is a distinct surface status on macOS and yields no texture.
  Treating it as success crashes inside `TextureCreateView`. Skip the frame.
- Zero-duration events need a minimum width of about one pixel or they become
  invisible and unclickable. Hit testing must use the same widened rectangle.
- A `.ttc` collection needs `GetFontOffsetForIndex`; offset zero is only correct
  for a single-face `.ttf`.
- First-frame cost is roughly 65 ms for shader and pipeline creation. Once per
  session, but a visible window should not appear before it completes.

## Mistakes worth not repeating

**Odin pads numeric format verbs with zeros.** `%-6d` prints 2373 as `237300`
and `%8.3f` prints 0.041 as `0000.041`. Every aligned numeric column must be
formatted to a string first. This produced garbage in three separate places
before the pattern was recognised.

**A cost that does not vary with workload is not a workload cost.** An early
frame-time measurement reported "8.4 ms, over budget" at every event count from
1,000 to 100,000. Under `Fifo` present mode, acquire and present block until the
next refresh: it was measuring a 120 Hz monitor.

**Measuring the wrong operation.** The first seek benchmark timed `seek` alone
and reported 0.079 ms p95 — true, and irrelevant. `seek` only moves a path map;
the budget is about producing file content, which needs `seek` plus `resolve`.
It would have claimed a 1200x margin on the wrong thing.

**A benchmark is only as good as its fixture.** With the generator's original
36-byte stub files, the corrected benchmark still read 0.081 ms. Nothing was
wrong with the harness; the input had no content to reconstruct. Realistic
200–600 line files moved the measurement by 50x.

**Writing a hash is not verifying one.** Baseline capture recorded
`entry.digest` from the first version and nothing ever read it — the manifest
kind alone decided the label, so an entry whose digest contradicted its content
was reported `Verified`. The field was dead and the code looked complete.

**Allocation dominates a scan.** Search took 110 ms per query because
`strings.to_lower` allocated a lowercase copy of every field of every event. The
tell was that a no-match query cost the same as one matching everything: if
matching were the expense, finding nothing would be cheap. Folding bytes in
place took it to 6 ms.

**An arena must be private to its owner.** Bounding the parser's memory by
resetting `context.temp_allocator` reclaimed memory the *caller* owned — and
callers allocate the source from it, which turned every test log into freed
memory after its first record.

**Scaled and unscaled units do not mix.** The timeline sized its label box from
an unscaled constant while the atlas was rasterized at display scale, so the
longer lane names were silently truncated on every high-DPI display. The box is
now derived from the viewport origin, which the caller has already scaled.

## Security gate findings

`scripts/test-security.sh` runs every fixture in `tests/fixtures/hostile`
through the built binary and asserts outcomes rather than mechanisms: no
sentinel file exists, the repository hash is unchanged, memory stayed bounded.

**One real crash, on the first run.** `encoding.jsonl` aborted with SIGTRAP
inside Odin's JSON string decoder, which sizes its output buffer from the input
length — but an invalid byte decodes to `RUNE_ERROR` and re-encodes to three
bytes, so a single stray `0xFF` writes past the end. A buffer overflow in a
parser handling untrusted input, reachable from any hostile log. Fixed by
validating UTF-8 at the trust boundary, which docs/08 required anyway, and kept
as a unit test so an upstream repair cannot silently remove the protection.

**Three checks that did not work.** Every check was deliberately broken to
confirm it fails. Three did not:

- *A check that could not fail.* The path-escape assertion searched
  `inspect --json` for `/etc/passwd`, but that command prints counts, never the
  path table. Disabling path normalization confirmed it: the trace contained
  `/etc/passwd` and the gate passed. It now searches the trace bytes.
- *Matching escaped content.* `grep "onload="` fires on `&lt;svg onload=…&gt;`,
  which is inert text and exactly what correct escaping produces. A gate that
  fails when the product is correct gets disabled.
- *Matching the defence as the attack.* Including `meta` in the active-element
  list flagged the report's own CSP declaration.

**A test that proved nothing.** Chip rectangles are both drawn and clicked, the
case docs/07 has in mind when prohibiting duplicate coordinate math. The obvious
test probes each recorded rectangle's own centre — and passes even when the
recorded rectangles are shifted away from where the chips were drawn, which is
the bug it existed to catch. Both sides came from one source. Reading the
rectangles back out of the draw list fixed it.

The general form: a test whose expectation and subject derive from one value
tests that value against itself.

## Open items

Not yet measured, none gating current work:

- the 30-minute stability run (30 seconds was measured);
- compression codec candidates, which matter before the trace format is declared
  stable;
- memory-mapped columnar query performance.
