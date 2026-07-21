# Rendering

## Stack

Norn uses:

- SDL3 for window creation, input, clipboard, cursors, and platform events;
- WGPU for GPU abstraction;
- a supported TrueType rasterizer for font glyph generation;
- custom Odin UI and visualization code.

The phase-zero spike validates SDL3 plus WGPU on macOS before the stack is
treated as irreversible. A fallback to SDL3's GPU API is allowed only through a
recorded architectural decision.

## Frame architecture

Each frame proceeds through:

```text
platform events
    -> application commands
    -> selection/filter update
    -> visible-data queries
    -> layout
    -> draw-list generation
    -> GPU batching
    -> submit and present
```

Product state is updated before drawing. Widgets do not directly mutate trace
data. Input produces commands, commands update application state, and panels
render the resulting state.

## Draw primitives

The renderer starts with a deliberately small set:

- solid and bordered rectangles;
- rounded rectangles;
- lines, polylines, and arrowheads;
- glyph quads;
- textured rectangles;
- clipped layers;
- instanced circles and graph nodes.

Timeline events, graph edges, and text are instanced. Similar primitives are
batched by pipeline, texture atlas, and clip rectangle.

## Coordinate spaces

- Window coordinates use logical UI pixels.
- Framebuffer coordinates account for display scale.
- Timeline coordinates use nanoseconds mapped through a viewport transform.
- Graph coordinates use layout units transformed by camera pan and zoom.
- Text layout uses logical pixels and snaps only at rasterization boundaries.

Hit testing uses the same transforms as drawing. Approximate duplicate math in
the UI layer is prohibited because it creates selection drift.

## Timeline virtualization

Only events intersecting the visible time interval and enabled lanes generate
draw instances. A range query returns a compact visible-event view; the panel
does not scan the full session each frame.

At distant zoom, events aggregate into fixed screen-space bins containing:

- event count by kind;
- total duration;
- outcome status counts;
- mutation density;
- error and retry markers.

Aggregation occurs in precomputed multiresolution levels. It must preserve the
visibility of failures and explicit bookmarks even when density is high.

## Repository graph

Graph layout runs off the main thread and publishes immutable position buffers.
Version one uses a deterministic two-dimensional force-directed layout seeded
from stable entity identifiers, with optional grouping by directory.

To keep the graph useful:

- default to touched entities only;
- impose a visible-node budget;
- expand neighborhoods on demand;
- keep selected and pinned nodes stable;
- fade rather than remove temporally inactive nodes during playback;
- label only selected, hovered, pinned, or sufficiently separated nodes.

The same trace and filters must produce the same initial layout.

## Text and diffs

The glyph atlas is generated lazily and cached by font, size, and scale factor.
Source text uses a monospace font; interface text may use a separate readable
font. Tabs have a configurable visual width but preserve original bytes.

The diff viewer virtualizes lines and syntax highlighting. Version one may use
token-level lexical highlighting for a small set of languages; accurate text
and change markers take priority over semantic coloring.

Long lines are clipped or horizontally scrolled, never silently wrapped in a
way that changes line-number alignment.

## Animation

Animation explains state change:

- playhead movement;
- graph node activation;
- panel focus transitions;
- newly visible evidence edges.

Animation does not delay input, change data order, or interpolate timestamps.
Reduced-motion mode replaces movement with immediate state changes and opacity
transitions where necessary.

## GPU resource lifecycle

- Static pipelines and atlases live for the application lifetime.
- Trace-specific buffers live for the open trace.
- Visible instance buffers use a ring sized for frames in flight.
- Resizing recreates only size-dependent targets.
- Device loss tears down GPU resources and attempts one clean reinitialization.
- CPU-side application state survives device reinitialization.

Resource destruction follows backend completion guarantees; Norn does not free
in-flight buffers based on frame count guesses.

## Performance budgets

Reference workload: 100,000 events, 10,000 entities, 50,000 edges, and a
4K-equivalent framebuffer on current Apple Silicon.

| Operation | Target |
| --- | ---: |
| Steady-state frame CPU time | under 8 ms p95 |
| GPU frame time | under 12 ms p95 |
| Input-to-selection update | under 50 ms p95 |
| Timeline range query | under 2 ms p95 |
| Visible instance generation | under 3 ms p95 |
| Graph snapshot swap | under 1 ms |
| Glyph-cache miss batch | no frame over 50 ms |

The application may reduce graph detail or animation under load. It must not
drop input events or show a stale time selection without an indicator.

## Diagnostics

A developer overlay reports:

- frame CPU and GPU time;
- draw calls and instances;
- decoded and cached trace bytes;
- visible and aggregated event counts;
- graph node and edge counts;
- worker queue depth;
- replay seek latency;
- glyph atlas occupancy.

Performance tests can capture these values in machine-readable form.
