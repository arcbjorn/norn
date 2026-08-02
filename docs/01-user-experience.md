# User experience

## Interaction model

Norn has one global selection:

- session;
- point or range in time;
- optional focused entity such as a file, symbol, command, test, or event.

Every panel reacts to that selection. The application must not allow the
timeline to show one moment while the diff or graph silently shows another.

## Opening a session

The initial window offers three actions:

1. Open an existing `.norn` trace.
2. Import a supported source trace.
3. Reopen a recent trace.

Import asks for the source log and repository root. Norn detects the importer,
shows the detected session metadata, and reports any unsupported record types
before writing output. The user chooses whether raw provider records are kept.

An import result must distinguish:

- imported records;
- ignored records with known reasons;
- malformed records;
- redacted values;
- file mutations that could not be replayed;
- timestamps that required repair.

Warnings do not disappear after the import dialog. They remain part of the
session metadata.

## Main workspace

```text
+-----------------------------------------------------------------------+
| Session | Search | Filters | Time | Import warnings | Export          |
+-------------------+--------------------------------+------------------+
|                   |                                |                  |
| Repository map    | Timeline                       | Inspector        |
| files / symbols   | agent, tools, edits, commands | event details    |
|                   | tests, errors, spans           | evidence        |
|                   |                                | attributes      |
+-------------------+--------------------------------+------------------+
| Diff / file replay / command output / test details                   |
+-----------------------------------------------------------------------+
```

The timeline is the largest panel. The lower panel changes representation
based on focus but never changes the global time selection.

## Timeline

Events appear in stable swimlanes:

1. user and agent messages;
2. tool calls and results;
3. file reads and mutations;
4. commands and processes;
5. tests and diagnostics;
6. errors and retries;
7. bookmarks and annotations.

Zoom levels change aggregation, not meaning:

- far: phases and density summaries;
- medium: spans, commands, edit groups, and test runs;
- near: individual events and durations.

At every zoom level, an event retains the same color family and shape. Color is
never the sole carrier of status.

## Time travel

Dragging the playhead updates the virtual repository and all derived panels.
Keyboard controls:

| Key | Action |
| --- | --- |
| Left / Right | Previous or next visible event |
| Shift + Left / Right | Previous or next mutation |
| Command + Left / Right | Previous or next outcome |
| Space | Play or pause automatic traversal |
| `[` / `]` | Set comparison range start or end |
| `F` | Focus selected entity across panels |
| `/` | Open search |
| `N` / Shift + `N` | Next or previous match, when search is closed |
| Return / Shift + Return | Next or previous match, while typing |
| Escape | Close search, then clear focus, then clear range |

While the search field has focus it receives every printable key, so `N` and
`D` type rather than navigate; Return steps matches in their place. Keys that
cannot appear in a query — arrows, brackets, and modified shortcuts — keep
their bindings, so opening search never traps the user in the field.

Playback is an inspection aid, not a video. It advances between meaningful
events and scales long idle gaps down.

## Diff and replay panel

For a selected file, the user can choose:

- state at playhead;
- diff from session start;
- diff from previous mutation;
- diff across the selected time range;
- final working-tree diff recorded by the trace.

Unknown or unverifiable content is shown explicitly. Norn must never fill a gap
with the current on-disk version of a file without labeling that substitution.

## Repository map

Version one uses a two-dimensional file and symbol map rather than decorative
three-dimensional graphics. Nodes represent files or symbols; edges represent
recorded or inferred relationships. The map supports:

- filter by touched, read, edited, tested, or failed;
- size by activity count or cumulative duration;
- color by outcome or recency;
- pin selected nodes;
- show only the neighborhood of the focused outcome.

Animation communicates change across time. It must not compromise selection
accuracy or make labels unreadable.

## Outcome-first diagnosis

Commands, test runs, diagnostics, and explicit errors are outcomes. Selecting
one opens an evidence stack:

1. the outcome itself;
2. directly attached parent events;
3. mutations since the last comparable successful outcome;
4. reads and tool results associated with those mutations;
5. inferred contributor candidates, ordered by confidence;
6. uncertainty and missing evidence.

The interface says “candidate contributor,” “preceded,” or “affected” unless an
explicit trace relationship establishes stronger semantics.

## Search and filtering

Search covers:

- event text and summaries;
- paths and symbol names;
- command lines and diagnostic messages;
- tool names and structured arguments;
- event and span identifiers.

Filters are composable and visible as removable chips. A hidden filter must
never explain an apparently missing event.

## Export

An export is a new artifact, not a screenshot. It contains:

- session and importer metadata;
- the selected time range;
- selected events and evidence edges;
- relevant diffs and outcomes;
- import warnings;
- a redaction manifest;
- a human-readable HTML report and canonical JSON data.

Exports exclude raw source records and unrelated prompt content by default.

## Accessibility

- All core operations must be keyboard-accessible.
- Text contrast targets WCAG AA.
- Status uses iconography and text in addition to color.
- Animation can be reduced or disabled.
- Timeline rows expose readable names and timestamps to platform accessibility
  APIs once the custom renderer supports them.
- Font size and UI scale are user-controlled.

## Empty and failure states

Empty panels explain why they are empty: no events, filtered out, unsupported
record, replay gap, or missing repository. Errors include the affected event or
path and a suggested corrective action. Norn does not present partial replay as
complete replay.
