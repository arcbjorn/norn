package analysis

import "core:strings"

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// Search and filtering.
//
// The searchable fields are the Field enum below; docs/01 fixes that list.
//
// One rule shapes the design: "a hidden filter must never explain an apparently
// missing event." Every result therefore carries which field matched, and every
// query reports what each filter removed — so "no results" always comes with
// its reason.

// Field identifies where a match was found.
//
// Reported per result so the UI can show why a row is present, and so a user
// searching for a path is not confused by a hit inside a command line that
// happens to mention it.
Field :: enum u8 {
	None = 0,
	Summary,
	Path,
	Symbol,
	Command_Line,
	Diagnostic_Message,
	Tool_Name,
	Tool_Arguments,
	Test_Name,
	Message_Text,
	Identifier,
}

field_name :: proc "contextless" (field: Field) -> string {
	switch field {
	case .None:               return "none"
	case .Summary:            return "summary"
	case .Path:               return "path"
	case .Symbol:             return "symbol"
	case .Command_Line:       return "command"
	case .Diagnostic_Message: return "diagnostic"
	case .Tool_Name:          return "tool"
	case .Tool_Arguments:     return "arguments"
	case .Test_Name:          return "test"
	case .Message_Text:       return "message"
	case .Identifier:         return "identifier"
	}
	return "unknown"
}

// Kind_Filter selects event families, matching the map filters in docs/01.
Kind_Filter :: enum u8 {
	Conversation,
	Tool,
	File,
	Command,
	Outcome,
	Extension,
}

Kind_Filters :: bit_set[Kind_Filter; u8]

// ALL_KINDS is the unfiltered state. An empty set would mean "nothing", which
// is a different thing and would hide every event by default.
ALL_KINDS :: Kind_Filters{.Conversation, .Tool, .File, .Command, .Outcome, .Extension}

// kind_family maps an event kind onto the filter it belongs to.
kind_family :: proc "contextless" (kind: model.Event_Kind) -> Kind_Filter {
	#partial switch kind {
	case .User_Message, .Agent_Message, .System_Message, .Summary:
		return .Conversation
	case .Tool_Call, .Tool_Result, .Tool_Error:
		return .Tool
	case .File_Read, .File_Create, .File_Modify, .File_Delete, .File_Rename,
	     .Directory_Observe:
		return .File
	case .Command_Start, .Command_Output, .Command_End, .Process_Spawn, .Process_Exit:
		return .Command
	case .Test_Run_Start, .Test_Case_Result, .Test_Run_End, .Diagnostic, .Build_Result,
	     .Lint_Result, .Explicit_Error:
		return .Outcome
	case .Extension_Event:
		return .Extension
	}
	// Session lifecycle and accounting events have no family of their own.
	// Grouping them with conversation keeps them visible by default rather than
	// invisible under every filter.
	return .Conversation
}

// Query is one search request.
Query :: struct {
	// Literal text, matched case-insensitively. Empty matches every event, so a
	// filter-only query is expressed by leaving this blank.
	text: string,
	// Event families to include.
	kinds: Kind_Filters,
	// Restrict to a time range. Zero end means no upper bound.
	start_ns: i64,
	end_ns:   i64,
	// Restrict to events naming this path entity. NO_ENTITY means any.
	path: model.Entity_Id,
	// Only events that are outcomes, and only failing ones.
	failed_only: bool,
	// Cap on results returned, so a query matching everything cannot exhaust
	// memory on a million-event trace.
	limit: int,
}

// DEFAULT_LIMIT bounds a query's results.
//
// docs/07 imposes visible-node budgets for the same reason: a list longer than
// this is not readable, and producing it costs time the user spends waiting.
DEFAULT_LIMIT :: 500

query_default :: proc() -> Query {
	return Query{kinds = ALL_KINDS, limit = DEFAULT_LIMIT}
}

// Match is one event the query selected.
Match :: struct {
	event:    model.Event_Id,
	sequence: model.Sequence,
	// Which field matched, so the UI can say why this row is here.
	field: Field,
	// Byte offset of the match within that field's text, for highlighting.
	offset: int,
	// The matched field's text, borrowed from the trace's string table.
	text: string,
}

// Results is what a query produced, with the accounting docs/01 requires.
Results :: struct {
	matches: [dynamic]Match,
	// Events considered, before any filter.
	examined: int,
	// Removed by each filter. docs/01: "a hidden filter must never explain an
	// apparently missing event" — these are what lets the UI say which filter
	// is responsible for an empty list.
	excluded_by_kind:  int,
	excluded_by_time:  int,
	excluded_by_path:  int,
	excluded_by_outcome: int,
	// Matched but beyond the limit. A truncated list that did not say so would
	// look like a complete answer.
	truncated: int,
}

results_destroy :: proc(results: ^Results) {
	delete(results.matches)
	results^ = {}
}

// search runs a query against an opened trace.
//
// Linear over events rather than index-backed: docs/09 budgets search latency,
// and a scan of a million events comparing a few interned strings is well
// inside it. An index would need to be built, kept current, and stored, which
// is cost paid on every trace to speed up an operation that is already fast.
search :: proc(
	trace: ^codec.Trace,
	query: Query,
	allocator := context.allocator,
) -> (
	results: Results,
	err: core.Error,
) {
	limit := query.limit if query.limit > 0 else DEFAULT_LIMIT
	results.matches = make([dynamic]Match, 0, min(limit, 64), allocator)

	needle := strings.to_lower(query.text, context.temp_allocator)
	defer delete(needle, context.temp_allocator)

	// A numeric query is also an identifier lookup. docs/01 lists event and
	// span identifiers among what search covers, and a user reading a report
	// has an event number rather than a phrase.
	wanted_id, is_identifier := parse_identifier(query.text)

	for event in trace.events {
		results.examined += 1

		if query.kinds != ALL_KINDS && kind_family(event.kind) not_in query.kinds {
			results.excluded_by_kind += 1
			continue
		}

		if !within_range(event, query) {
			results.excluded_by_time += 1
			continue
		}

		if query.path != model.NO_ENTITY && event.primary_entity_id != query.path {
			results.excluded_by_path += 1
			continue
		}

		if query.failed_only && !is_failing(trace, event) {
			results.excluded_by_outcome += 1
			continue
		}

		if needle == "" && !is_identifier {
			// A filter-only query: every surviving event is a result.
			append_match(&results, event, Match{field = .None}, limit)
			continue
		}

		if is_identifier && u64(event.id) == wanted_id {
			append_match(
				&results,
				event,
				Match{field = .Identifier, text = ""},
				limit,
			)
			continue
		}

		if match, found := match_event(trace, event, needle); found {
			append_match(&results, event, match, limit)
		}
	}

	return results, nil
}

@(private)
append_match :: proc(results: ^Results, event: model.Event, match: Match, limit: int) {
	if len(results.matches) >= limit {
		results.truncated += 1
		return
	}
	complete := match
	complete.event = event.id
	complete.sequence = event.sequence
	append(&results.matches, complete)
}

@(private)
within_range :: proc(event: model.Event, query: Query) -> bool {
	if query.start_ns == 0 && query.end_ns == 0 {
		return true
	}
	if .Has_Wall_Time not_in event.flags {
		// An event without a timestamp cannot be placed in a range. Excluding
		// it is the honest answer; including it would put it at a time the
		// trace never recorded.
		return false
	}
	if query.start_ns != 0 && event.wall_time_ns < query.start_ns {
		return false
	}
	if query.end_ns != 0 && event.wall_time_ns > query.end_ns {
		return false
	}
	return true
}

@(private)
is_failing :: proc(trace: ^codec.Trace, event: model.Event) -> bool {
	#partial switch event.kind {
	case .Tool_Error, .Explicit_Error:
		return true
	case .Command_End, .Command_Start:
		payload, found := model.get_command(&trace.payloads, event.payload)
		return found && payload.status == .Failed
	case .Test_Case_Result:
		payload, found := model.get_test(&trace.payloads, event.payload)
		return found && (payload.status == .Failed || payload.status == .Errored)
	case .Diagnostic:
		payload, found := model.get_diagnostic(&trace.payloads, event.payload)
		return found && (payload.severity == .Error || payload.severity == .Fatal)
	case .Build_Result, .Lint_Result:
		return true
	}
	return false
}

// match_event tests every searchable field of one event.
//
// Ordered from most specific to least: a query naming a path should report the
// path as the reason rather than a summary that happens to contain it.
@(private)
match_event :: proc(
	trace: ^codec.Trace,
	event: model.Event,
	needle: string,
) -> (
	match: Match,
	found: bool,
) {
	// Typed payloads first.
	#partial switch model.Payload_Group(event.payload.group) {
	case .Command:
		if payload, ok := model.get_command(&trace.payloads, event.payload); ok {
			if hit, at := contains_fold(trace, payload.command_line, needle); hit {
				return Match{field = .Command_Line, offset = at, text = text_of(trace, payload.command_line)}, true
			}
		}
	case .Diagnostic:
		if payload, ok := model.get_diagnostic(&trace.payloads, event.payload); ok {
			if hit, at := contains_fold(trace, payload.message, needle); hit {
				return Match{field = .Diagnostic_Message, offset = at, text = text_of(trace, payload.message)}, true
			}
			if hit, at := contains_fold(trace, payload.code, needle); hit {
				return Match{field = .Diagnostic_Message, offset = at, text = text_of(trace, payload.code)}, true
			}
		}
	case .Tool:
		if payload, ok := model.get_tool(&trace.payloads, event.payload); ok {
			if hit, at := contains_fold(trace, payload.call_id, needle); hit {
				return Match{field = .Tool_Name, offset = at, text = text_of(trace, payload.call_id)}, true
			}
			// Structured arguments live in a blob. docs/01 lists them among
			// what search covers, so the bytes are examined rather than skipped
			// for being out of the string table.
			if hit, at := blob_contains(trace, payload.content, needle); hit {
				return Match{field = .Tool_Arguments, offset = at}, true
			}
		}
	case .Message:
		if payload, ok := model.get_message(&trace.payloads, event.payload); ok {
			if hit, at := contains_fold(trace, payload.summary, needle); hit {
				return Match{field = .Message_Text, offset = at, text = text_of(trace, payload.summary)}, true
			}
			if hit, at := blob_contains(trace, payload.text, needle); hit {
				return Match{field = .Message_Text, offset = at}, true
			}
		}
	case .Test_Case:
		if payload, ok := model.get_test(&trace.payloads, event.payload); ok {
			if hit, at := entity_contains(trace, payload.test_case, needle); hit {
				return Match{field = .Test_Name, offset = at, text = entity_text(trace, payload.test_case)}, true
			}
			if hit, at := contains_fold(trace, payload.message, needle); hit {
				return Match{field = .Test_Name, offset = at, text = text_of(trace, payload.message)}, true
			}
		}
	}

	// Entities the event names: paths and symbols.
	for entity_id in ([]model.Entity_Id{event.primary_entity_id, event.actor_entity_id}) {
		if entity_id == model.NO_ENTITY {
			continue
		}
		if hit, at := entity_contains(trace, entity_id, needle); hit {
			field := Field.Path
			if entity, ok := entity_by_id(trace, entity_id); ok && entity.kind == .Symbol {
				field = .Symbol
			}
			return Match{field = field, offset = at, text = entity_text(trace, entity_id)}, true
		}
	}

	// The summary last: it is a display label, and a hit there is the weakest
	// explanation of why a row appeared.
	if hit, at := contains_fold(trace, event.summary_string_id, needle); hit {
		return Match{field = .Summary, offset = at, text = text_of(trace, event.summary_string_id)}, true
	}

	return {}, false
}

// MAX_SEARCHED_BLOB_BYTES bounds how much of a blob a query examines.
//
// A message or tool result can hold megabytes. Scanning all of it for every
// event would make search cost scale with content rather than with event count,
// and a match past this point is not one a user would find useful anyway.
MAX_SEARCHED_BLOB_BYTES :: 64 * 1024

@(private)
blob_contains :: proc(
	trace: ^codec.Trace,
	blob: model.Blob_Id,
	needle: string,
) -> (
	found: bool,
	offset: int,
) {
	if blob == model.NO_BLOB || needle == "" {
		return false, 0
	}
	content, err := codec.trace_blob_content(trace, blob)
	if !core.ok(err) {
		return false, 0
	}
	limited := content
	if len(limited) > MAX_SEARCHED_BLOB_BYTES {
		limited = limited[:MAX_SEARCHED_BLOB_BYTES]
	}

	at := index_fold(string(limited), needle)
	if at < 0 {
		return false, 0
	}
	return true, at
}

@(private)
contains_fold :: proc(
	trace: ^codec.Trace,
	id: model.String_Id,
	needle: string,
) -> (
	found: bool,
	offset: int,
) {
	if id == model.EMPTY_STRING || needle == "" {
		return false, 0
	}
	value, ok := model.string_get(&trace.strings, id)
	if !ok || value == "" {
		return false, 0
	}

	at := index_fold(value, needle)
	if at < 0 {
		return false, 0
	}
	return true, at
}

// index_fold finds `needle` in `haystack`, comparing ASCII case-insensitively.
//
// Allocation-free, which is the whole point. Lowering each field into temporary
// memory cost 110 ms per query on a seventy-thousand-event trace — the
// allocation dominated, since a query matching nothing cost the same as one
// matching everything. Comparing in place is two orders of magnitude cheaper
// and lets search run on every keystroke.
//
// `needle` must already be lowercase; the caller lowers it once per query
// rather than once per field.
@(private)
index_fold :: proc(haystack: string, needle: string) -> int {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return -1
	}

	first := needle[0]
	limit := len(haystack) - len(needle)

	outer: for start in 0 ..= limit {
		if fold(haystack[start]) != first {
			continue
		}
		for offset in 1 ..< len(needle) {
			if fold(haystack[start + offset]) != needle[offset] {
				continue outer
			}
		}
		return start
	}
	return -1
}

// fold lowers one ASCII byte.
//
// ASCII only: a full Unicode case fold needs a table and per-rune decoding, and
// the fields searched here are paths, identifiers, and command lines. Non-ASCII
// text still matches exactly, which is the behaviour a user typing a literal
// expects — it simply is not case-insensitive beyond ASCII.
@(private)
fold :: proc "contextless" (c: byte) -> byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

@(private)
entity_contains :: proc(
	trace: ^codec.Trace,
	id: model.Entity_Id,
	needle: string,
) -> (
	found: bool,
	offset: int,
) {
	entity, ok := entity_by_id(trace, id)
	if !ok {
		return false, 0
	}
	return contains_fold(trace, entity.name, needle)
}

@(private)
entity_by_id :: proc(
	trace: ^codec.Trace,
	id: model.Entity_Id,
) -> (
	entity: model.Entity,
	found: bool,
) {
	// Entity identifiers are one-based and match their slice position, which
	// the codec validates on open.
	index := int(id) - 1
	if index < 0 || index >= len(trace.entities) {
		return {}, false
	}
	return trace.entities[index], true
}

@(private)
entity_text :: proc(trace: ^codec.Trace, id: model.Entity_Id) -> string {
	entity, ok := entity_by_id(trace, id)
	if !ok {
		return ""
	}
	return text_of(trace, entity.name)
}

@(private)
text_of :: proc(trace: ^codec.Trace, id: model.String_Id) -> string {
	value, _ := model.string_get(&trace.strings, id)
	return value
}

// parse_identifier recognises a bare number as an identifier lookup.
@(private)
parse_identifier :: proc(text: string) -> (value: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return 0, false
	}
	result := u64(0)
	for index in 0 ..< len(trimmed) {
		c := trimmed[index]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		// Overflow-checked, because the input is a user string and docs/08
		// requires every length and count from untrusted input to be checked
		// before use.
		scaled, mul_ok := core.mul_u64(result, 10)
		if !mul_ok {
			return 0, false
		}
		summed, add_ok := core.add_u64(scaled, digit)
		if !add_ok {
			return 0, false
		}
		result = summed
	}
	return result, true
}

// active_filter_count reports how many filters are narrowing a query.
//
// docs/01 shows filters as removable chips, and the count is what tells a user
// that an empty result has an explanation other than "nothing matched".
active_filter_count :: proc(query: Query) -> int {
	count := 0
	if query.kinds != ALL_KINDS {
		count += 1
	}
	if query.start_ns != 0 || query.end_ns != 0 {
		count += 1
	}
	if query.path != model.NO_ENTITY {
		count += 1
	}
	if query.failed_only {
		count += 1
	}
	return count
}

// excluded_total sums what the filters removed.
excluded_total :: proc(results: ^Results) -> int {
	return(
		results.excluded_by_kind +
		results.excluded_by_time +
		results.excluded_by_path +
		results.excluded_by_outcome \
	)
}
