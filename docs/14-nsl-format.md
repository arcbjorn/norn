# Norn Session Log (NSL)

## Why this format exists

docs/05 requires that adapter support rest on fixtures rather than on
assumptions, and that the first supported schema be "locked by sanitized
fixtures". A provider's own format cannot be locked that way until real sample
traces are available, and docs/05 is explicit that "Codex JSONL" is not itself a
sufficiently precise compatibility promise.

NSL is a session log format Norn defines and owns. Because Norn controls the
schema, it can be specified exactly, generated deterministically, and used to
exercise every requirement in the adapter contract without waiting on a sample
of anyone's private session. It serves three purposes:

1. It is the fixture format for the tiers in docs/09 — tiny, representative,
   reference, and stress.
2. It is a worked reference for future provider adapters: the NSL adapter maps
   every canonical event kind, so a new adapter has an example of each case.
3. It gives `norn import` something real to import in a build that carries no
   provider adapter.

NSL is not a provider format and makes no claim to resemble one. A provider
adapter is a separate adapter with its own detection and its own fixtures.

## Encoding

One JSON object per line, UTF-8, newline-separated. A trailing newline is
optional. Blank lines are skipped and are not counted as records.

The parser reads one line at a time and parses each independently, so memory is
bounded by the longest single record rather than by the file, as docs/05
requires.

## Header record

The first non-blank line must be a header:

```json
{"type":"session","nsl_version":1,"generator":"norn-fixture/1","session":"tiny-01"}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `type` | yes | Always `"session"` |
| `nsl_version` | yes | Schema version; `1` is the only supported value |
| `generator` | no | What produced the log, for provenance |
| `session` | no | A name for the session |
| `started_at` | no | Session start, nanoseconds since the Unix epoch |

The version field is what makes detection decisive rather than a guess: a file
whose first record declares `nsl_version` is NSL, and a file that does not is
not claimed. This is the "version marker or equally decisive signal" that
docs/05 requires for `Certain` confidence.

An unknown `nsl_version` is refused rather than parsed optimistically. Reading a
future schema with version-one rules would produce a plausible trace of a
session that did not happen.

## Common record fields

Every record after the header carries:

| Field | Required | Meaning |
| --- | --- | --- |
| `type` | yes | Record kind, from the table below |
| `t` | no | Wall-clock time, nanoseconds since the Unix epoch |

A record without `t` is imported with its timestamp absent and counted, per
docs/03: an absent timestamp is recorded as absent, never invented.

## Record types

### `message`

Visible conversation text.

```json
{"type":"message","t":1,"role":"user","text":"make the tests pass"}
```

`role` is `user`, `assistant`, or `system`. An unknown role is a warning and the
record maps to a system message rather than being dropped.

`goal` may be set to `true` on a user message to mark it as stating a goal,
which attempt detection uses as a boundary.

Only visible text appears here. docs/03 forbids inventing hidden reasoning
events, so NSL has no field for them.

### `tool_call` and `tool_result`

```json
{"type":"tool_call","t":2,"id":"c1","tool":"edit_file","arguments":{"path":"src/main.odin"}}
{"type":"tool_result","t":3,"id":"c1","status":"ok","content":"applied"}
```

`id` pairs a result with its call. docs/05 requires explicit identifiers to be
used when available; a result whose `id` matches no call is imported and a
warning is recorded rather than the pairing being guessed by proximity.

`status` is `ok` or `error`. An `error` result maps to a tool-error event and
carries `error` as its message.

`arguments` and `content` may be any JSON value. When either is an object or
array it is stored as a structured blob and marked structured; a string is
stored as opaque text. This is docs/03's rule that tool payloads are structured
blobs when valid JSON and opaque text otherwise.

### `file`

A file observation or mutation.

```json
{"type":"file","t":4,"op":"modify","path":"src/main.odin","before":"old\n","after":"new\n"}
```

`op` is `read`, `create`, `modify`, `delete`, or `rename`. A rename requires
`from`. Paths are repository-relative; an absolute path, a drive prefix, or a
path containing `..` is refused, matching the normalization in `src/core`.

Content evidence follows the preference order in docs/05. `before` and `after`
together produce a replayable mutation; `patch` with `before` does the same; a
record with neither is a provider-declared mutation without enough content to
replay, and is recorded as such rather than being dropped or guessed at.

### `command`

```json
{"type":"command","t":5,"command":"odin test tests/core","argv":["odin","test","tests/core"],
 "exit":0,"output":"All tests successful","duration_ns":1000000}
```

`command` is the command line as text and is never parsed into an argument
vector. `argv` is used only when the source supplies a real vector, keeping
docs/03's separation between a trustworthy argv and a display string.

`output` is command output, kept distinct from `diagnostic` records so that
docs/05's requirement to separate command output from application diagnostics
holds.

### `diagnostic`

```json
{"type":"diagnostic","t":6,"severity":"error","path":"src/main.odin","line":12,
 "column":3,"code":"E0001","message":"undefined identifier"}
```

`severity` is `error`, `warning`, `info`, or `hint`.

### `test`

```json
{"type":"test","t":7,"name":"parses_a_header","suite":"nsl","status":"fail",
 "message":"expected 1, got 0","path":"tests/nsl/test_parse.odin","line":40}
```

`status` is `pass`, `fail`, `skip`, or `error`. `name` is the stable test
identity docs/06 requires for comparability.

### Unknown types

A record whose `type` is not listed above is retained as an extension event
carrying its raw text, per docs/05 requirement 9. It is counted as an extension
event, not as an ignored record.

A record that is not a JSON object, or whose `type` is missing or not a string,
cannot be retained meaningfully. It is counted as ignored and a warning is
recorded.

## Malformed input

A line that does not parse as JSON is counted as ignored with a warning, and the
import continues. A truncated final line is the common case and refusing the
whole log for it would discard a session that is otherwise entirely readable.

Refusal is reserved for what makes the log meaningless: a missing or malformed
header, or an unsupported `nsl_version`.
