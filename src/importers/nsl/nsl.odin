package importer_nsl

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:core"
import api "src:importers/api"
import "src:trace/codec"
import "src:trace/model"

// The Norn Session Log adapter.
//
// docs/14-nsl-format.md defines the format and why it exists: docs/05 requires
// adapter support to rest on fixtures rather than assumptions, and a provider's
// schema cannot be locked that way until real samples exist. NSL is a format
// Norn owns, so it can be specified exactly and generated deterministically.
//
// This adapter is also the worked reference for the ten mapping requirements in
// docs/05. Every canonical event kind an adapter is expected to produce appears
// below, so a future provider adapter has an example of each case.

ID :: "nsl"
VERSION :: "1.0.0"

// SUPPORTED_VERSION is the only schema version this adapter reads.
//
// An unknown version is refused rather than parsed optimistically: reading a
// future schema with version-one rules would produce a plausible-looking trace
// of a session that did not happen.
SUPPORTED_VERSION :: 1

// importer returns the adapter definition for registration.
importer :: proc() -> api.Importer {
	return api.Importer {
		id = ID,
		version = VERSION,
		detect = detect,
		inspect = inspect,
		import_source = import_source,
	}
}

// detect claims a source whose first record declares an NSL version.
//
// docs/05 requires a "version marker or equally decisive signal" for Certain
// confidence. A bare JSONL file is only Possible: docs/05 is explicit that a
// file is not a given format merely because it is JSONL.
detect :: proc(prefix: []byte, path_hint: string) -> api.Detection {
	detection: api.Detection

	line, _ := first_line(string(prefix))
	if line == "" {
		return detection
	}

	// Detection reads the header only, and never parses the whole prefix:
	// detection runs against every registered adapter, and a hostile file
	// should not be parsed once per adapter.
	value, err := json.parse_string(line, allocator = context.temp_allocator)
	if err != nil {
		return detection
	}

	object, is_object := value.(json.Object)
	if !is_object {
		return detection
	}

	if kind, _ := string_field(object, "type"); kind != "session" {
		// A JSON object per line, but not an NSL header. Another JSONL format
		// could look like this, so the claim stays weak.
		if strings.has_suffix(path_hint, ".jsonl") {
			detection.confidence = .Possible
			api.add_reason(&detection, "JSON object records, but no NSL header")
		}
		return detection
	}

	version, has_version := integer_field(object, "nsl_version")
	if !has_version {
		detection.confidence = .Possible
		api.add_reason(&detection, "a session header without a version marker")
		return detection
	}

	if version != SUPPORTED_VERSION {
		// Recognized decisively, but not readable. Claiming it is what produces
		// a clear "unsupported version" error instead of "no importer
		// recognizes this file".
		detection.confidence = .Certain
		api.add_reason(&detection, "an NSL header declaring an unsupported version")
		return detection
	}

	detection.confidence = .Certain
	api.add_reason(&detection, "an NSL session header")
	api.add_reason(&detection, "a supported schema version")
	return detection
}

// inspect reports what the source contains without producing a trace.
inspect :: proc(
	source: []byte,
	allocator: mem.Allocator,
) -> (
	metadata: api.Source_Metadata,
	err: core.Error,
) {
	metadata.size_bytes = u64(len(source))
	metadata.unsupported_types = make([dynamic]string, 0, 4, allocator)

	rest := string(source)
	line, ok := next_record(&rest)
	if !ok {
		return metadata, core.err_make(.Malformed_Container, "the log is empty")
	}

	header, header_err := parse_header(line)
	if !core.ok(header_err) {
		return metadata, header_err
	}
	metadata.variant = header.variant

	// Counting requires reading every line, but each is parsed and released
	// independently, so memory stays bounded by the longest record.
	seen: map[string]bool
	defer delete(seen)

	for {
		record, more := next_record(&rest)
		if !more {
			break
		}
		metadata.record_count += 1

		value, parse_err := json.parse_string(record, allocator = context.temp_allocator)
		if parse_err != nil {
			continue
		}
		object, is_object := value.(json.Object)
		if !is_object {
			continue
		}

		kind, has_kind := string_field(object, "type")
		if !has_kind {
			continue
		}

		switch kind {
		case "message":
			metadata.expected.conversation = true
		case "tool_call", "tool_result":
			metadata.expected.tool_calls = true
		case "file":
			metadata.expected.file_mutations = true
		case "command":
			metadata.expected.command_output = true
		case "test":
			metadata.expected.structured_tests = true
		case "diagnostic":
		// Diagnostics have no capability flag of their own.
		case:
			// docs/05 requires unsupported record types to be reported rather
			// than silently dropped. Named once each, because a count alone
			// does not tell a user whether they were the records they cared
			// about.
			if !seen[kind] {
				seen[kind] = true
				append(&metadata.unsupported_types, strings.clone(kind, allocator))
			}
		}

		if _, has_time := integer_field(object, "t"); has_time {
			metadata.expected.timestamps = true
		}
	}

	return metadata, nil
}

@(private)
Header :: struct {
	variant:    string,
	started_at: i64,
}

@(private)
parse_header :: proc(line: string) -> (header: Header, err: core.Error) {
	value, parse_err := json.parse_string(line, allocator = context.temp_allocator)
	if parse_err != nil {
		return {}, core.err_make(.Malformed_Container, "the header is not valid JSON")
	}

	object, is_object := value.(json.Object)
	if !is_object {
		return {}, core.err_make(.Malformed_Container, "the header is not an object")
	}

	if kind, _ := string_field(object, "type"); kind != "session" {
		return {}, core.err_make(.Malformed_Container, "the log does not begin with a header")
	}

	version, has_version := integer_field(object, "nsl_version")
	if !has_version {
		return {}, core.err_make(.Malformed_Container, "the header declares no version")
	}
	if version != SUPPORTED_VERSION {
		return {}, core.err_make(.Unsupported_Version, "unsupported NSL version")
	}

	header.variant = "nsl v1"
	header.started_at, _ = integer_field(object, "started_at")
	return header, nil
}

// Import_State tracks what pairing and span recovery need across records.
@(private)
Import_State :: struct {
	sink: ^api.Sink,
	// Open tool calls by provider identifier, so a result pairs with its call
	// using an explicit identifier rather than proximity.
	calls: map[string]Open_Call,
	// The agent actor, created once so the map does not show one node per turn.
	agent: model.Entity_Id,
	user:  model.Entity_Id,
	record_number: u64,
	byte_offset:   u64,
}

@(private)
Open_Call :: struct {
	span:  model.Span_Id,
	event: model.Event_Id,
	tool:  model.Entity_Id,
}

// import_source converts an NSL log into canonical records.
import_source :: proc(source: []byte, sink: ^api.Sink, options: api.Options) -> core.Error {
	rest := string(source)

	line, ok := next_record(&rest)
	if !ok {
		return core.err_make(.Malformed_Container, "the log is empty")
	}
	header := parse_header(line) or_return

	state := Import_State {
		sink = sink,
	}
	state.calls = make(map[string]Open_Call, 16, context.temp_allocator)
	defer delete(state.calls)

	state.agent = api.add_entity(sink, .Actor_Agent, "assistant", "")
	state.user = api.add_entity(sink, .Actor_User, "user", "")

	// docs/05: the capability manifest records what the source actually
	// provided. These are declared as records are seen, not up front, so a log
	// that happens to contain no tool calls does not claim to support them.
	api.declare_capability(sink, .Stable_Event_Ids)

	if header.started_at != 0 {
		api.add_event(
			sink,
			api.Event_Input {
				kind = .Session_Start,
				wall_time_ns = header.started_at,
				has_wall_time = true,
				summary = "session start",
				source_type = "session",
			},
		)
	}

	for {
		record, more := next_record(&rest)
		if !more {
			break
		}
		state.record_number += 1
		sink.report.source_records += 1

		import_record(&state, record)

		state.byte_offset += u64(len(record)) + 1
	}

	// docs/03: "import must not synthesize a successful end for a span that
	// simply stops." An unpaired call keeps its Incomplete flag and is counted.
	for _, call in state.calls {
		_ = call
		api.note_warning(sink, .Span_Incomplete)
	}

	return nil
}

@(private)
import_record :: proc(state: ^Import_State, record: string) {
	sink := state.sink

	value, parse_err := json.parse_string(record, allocator = context.temp_allocator)
	if parse_err != nil {
		// A truncated final line is the common case, and refusing the whole log
		// for it would discard a session that is otherwise entirely readable.
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
		return
	}

	object, is_object := value.(json.Object)
	if !is_object {
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
		return
	}

	kind, has_kind := string_field(object, "type")
	if !has_kind {
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
		return
	}

	switch kind {
	case "message":     import_message(state, object)
	case "tool_call":   import_tool_call(state, object)
	case "tool_result": import_tool_result(state, object)
	case "file":        import_file(state, object)
	case "command":     import_command(state, object)
	case "diagnostic":  import_diagnostic(state, object)
	case "test":        import_test(state, object)
	case "session":
		// A second header. Harmless, but not a record.
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
	case:
		import_unknown(state, kind, record)
	}
}

// timing pulls the common envelope fields off a record.
@(private)
timing :: proc(object: json.Object) -> (wall_time: i64, has_time: bool) {
	return integer_field(object, "t")
}

@(private)
base_input :: proc(
	state: ^Import_State,
	object: json.Object,
	kind: model.Event_Kind,
	source_type: string,
) -> api.Event_Input {
	wall_time, has_time := timing(object)
	return api.Event_Input {
		kind = kind,
		wall_time_ns = wall_time,
		has_wall_time = has_time,
		source_type = source_type,
		record_number = state.record_number,
		byte_offset = state.byte_offset,
	}
}

@(private)
import_message :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink
	api.declare_capability(sink, .Conversation_Text)

	role, _ := string_field(object, "role")
	text, _ := string_field(object, "text")

	kind: model.Event_Kind
	actor: model.Entity_Id
	switch role {
	case "user":
		kind = .User_Message
		actor = state.user
	case "assistant":
		kind = .Agent_Message
		actor = state.agent
	case "system":
		kind = .System_Message
	case:
		// Mapped rather than dropped: the text was visible in the session, and
		// an unknown role is a reason to warn, not to discard content.
		kind = .System_Message
		api.note_warning(sink, .Unsupported_Record)
	}

	// docs/03: conversation events carry visible text only. There is no field
	// here for hidden reasoning because Norn never invents one.
	blob := api.add_blob_text(sink, text)
	goal, _ := boolean_field(object, "goal")

	payload := model.add_message(
		&sink.payloads,
		model.Message_Payload {
			text = blob,
			summary = api.intern_text(sink, summarize(text)),
			goal_bearing = goal && kind == .User_Message,
		},
	)

	input := base_input(state, object, kind, "message")
	input.actor = actor
	input.summary = summarize(text)
	input.payload = payload
	api.add_event(sink, input)
}

@(private)
import_tool_call :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink
	api.declare_capability(sink, .Structured_Tool_Calls)

	name, _ := string_field(object, "tool")
	if name == "" {
		name = "unknown"
	}
	tool := api.add_entity(sink, .Actor_Tool, name, "")

	content, structured := json_content(object, "arguments")
	blob := api.add_blob_text(sink, content)

	call_id, has_id := string_field(object, "id")

	// docs/03: a span covers the tool lifecycle. It opens here and closes when
	// the matching result arrives.
	span := api.add_span(sink, .Tool_Invocation, name)

	payload := model.add_tool(
		&sink.payloads,
		model.Tool_Payload {
			tool = tool,
			call_id = api.intern_text(sink, call_id),
			content = blob,
			structured = structured,
			status = .Running,
		},
	)

	input := base_input(state, object, .Tool_Call, "tool_call")
	input.actor = state.agent
	input.primary = tool
	input.span = span
	input.summary = name
	input.payload = payload
	event := api.add_event(sink, input)

	if has_id && call_id != "" {
		if _, already := state.calls[call_id]; already {
			// Two calls sharing an identifier make pairing ambiguous. The later
			// one wins and the collision is recorded rather than hidden.
			api.note_warning(sink, .Ambiguous_Pairing)
		}
		state.calls[call_id] = Open_Call{span = span, event = event, tool = tool}
	} else {
		// Without an identifier there is nothing to pair against. docs/05 wants
		// explicit identifiers used when available; guessing by proximity when
		// they are absent would invent a relationship.
		api.note_warning(sink, .Ambiguous_Pairing)
	}
}

@(private)
import_tool_result :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink

	call_id, _ := string_field(object, "id")
	call, paired := state.calls[call_id]
	if paired {
		delete_key(&state.calls, call_id)
	} else {
		// A result naming no call is imported and counted. Attaching it to the
		// nearest call would fabricate a pairing the source never stated.
		api.note_warning(sink, .Ambiguous_Pairing)
	}

	status_text, _ := string_field(object, "status")
	failed := status_text == "error"

	content, structured := json_content(object, "content")
	blob := api.add_blob_text(sink, content)
	message, _ := string_field(object, "error")

	tool := call.tool
	if tool == model.NO_ENTITY {
		tool = api.add_entity(sink, .Actor_Tool, "unknown", "")
	}

	payload := model.add_tool(
		&sink.payloads,
		model.Tool_Payload {
			tool = tool,
			call_id = api.intern_text(sink, call_id),
			content = blob,
			structured = structured,
			status = .Failed if failed else .Passed,
			error_message = api.intern_text(sink, message),
		},
	)

	kind := model.Event_Kind.Tool_Error if failed else model.Event_Kind.Tool_Result
	input := base_input(state, object, kind, "tool_result")
	input.actor = state.agent
	input.primary = tool
	input.span = call.span
	input.summary = message if failed && message != "" else "tool result"
	input.payload = payload
	api.add_event(sink, input)

	if paired {
		api.close_span(sink, call.span, call.event)
	}
}

@(private)
import_file :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink

	raw_path, _ := string_field(object, "path")
	path, rejection := core.normalize_path(raw_path, context.temp_allocator)
	if rejection != .None {
		// docs/08: a path is never resolved outside the repository boundary.
		// The record is refused rather than clamped, because a clamped path
		// names a different file than the session touched.
		api.note_warning(sink, .Path_Rejected)
		api.note_ignored(sink)
		return
	}

	op_text, _ := string_field(object, "op")
	kind: model.Event_Kind
	switch op_text {
	case "read":   kind = .File_Read
	case "create": kind = .File_Create
	case "modify": kind = .File_Modify
	case "delete": kind = .File_Delete
	case "rename": kind = .File_Rename
	case:
		api.note_warning(sink, .Unsupported_Record)
		api.note_ignored(sink)
		return
	}

	path_entity := api.add_entity(sink, .Path, path, "")

	input := base_input(state, object, kind, "file")
	input.actor = state.agent
	input.primary = path_entity
	input.summary = op_text
	event := api.add_event(sink, input)

	if kind == .File_Read {
		api.declare_capability(sink, .File_Reads)
		return
	}

	import_mutation(state, object, event, path_entity, kind)
}

@(private)
import_mutation :: proc(
	state: ^Import_State,
	object: json.Object,
	event: model.Event_Id,
	path: model.Entity_Id,
	kind: model.Event_Kind,
) {
	sink := state.sink

	mutation := model.Mutation {
		event_id = event,
		path     = path,
		op       = model.mutation_op_for_kind(kind),
		encoding = .Utf8,
	}

	if kind == .File_Rename {
		raw_from, has_from := string_field(object, "from")
		from, rejection := core.normalize_path(raw_from, context.temp_allocator)
		if !has_from || rejection != .None {
			// docs/03: a rename must name the path it moved from. Without one
			// the record cannot describe a rename, so it degrades to a modify
			// rather than being written as an invalid mutation.
			api.note_warning(sink, .Malformed_Record)
			mutation.op = .Modify
		} else {
			mutation.old_path = api.add_entity(sink, .Path, from, "")
		}
	}

	before, has_before := string_field(object, "before")
	after, has_after := string_field(object, "after")
	patch, has_patch := string_field(object, "patch")

	// docs/05 preference order: explicit before and after content is strongest,
	// then a patch with verified before content. A record with neither is a
	// provider-declared mutation that cannot be replayed, and says so.
	switch {
	case has_before && has_after:
		mutation.content_blob = api.add_blob_text(sink, after)
		mutation.flags += {.Has_Content}
		record_hashes(sink, &mutation, before, after)
		mutation.status = .Reconstructed_Unverified
		api.declare_capability(sink, .Before_After_Content)

	case has_patch && has_before:
		mutation.patch_blob = api.add_blob_text(sink, patch)
		mutation.flags += {.Has_Patch}
		record_hashes(sink, &mutation, before, "")
		mutation.status = .Reconstructed_Unverified
		api.declare_capability(sink, .Patches)

	case has_after:
		mutation.content_blob = api.add_blob_text(sink, after)
		mutation.flags += {.Has_Content}
		record_hashes(sink, &mutation, "", after)
		mutation.status = .Reconstructed_Unverified
		api.declare_capability(sink, .Before_After_Content)

	case kind == .File_Delete:
		// A delete needs no content to be complete.
		mutation.status = .Reconstructed_Unverified

	case:
		// docs/06: a mutation without enough content to replay is recorded as a
		// gap, never silently completed from later state.
		mutation.status = .Missing_Baseline
		api.note_warning(sink, .Missing_Baseline)
	}

	api.add_mutation(sink, mutation)
}

// record_hashes stores content digests so replay can verify a reconstruction.
@(private)
record_hashes :: proc(
	sink: ^api.Sink,
	mutation: ^model.Mutation,
	before: string,
	after: string,
) {
	if before != "" {
		mutation.before_hash = api.content_digest(sink, before)
		mutation.flags += {.Has_Before_Hash}
	}
	if after != "" {
		mutation.after_hash = api.content_digest(sink, after)
		mutation.flags += {.Has_After_Hash}
	}
}

@(private)
import_command :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink
	api.declare_capability(sink, .Command_Boundaries)

	line, _ := string_field(object, "command")
	if line == "" {
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
		return
	}

	command := api.add_entity(sink, .Command, line, "")
	span := api.add_span(sink, .Command_Execution, line)

	exit_code, has_exit := integer_field(object, "exit")
	status := model.Outcome_Status.Unknown
	if has_exit {
		status = .Passed if exit_code == 0 else .Failed
	}

	// docs/03: a shell command string is never parsed as if it were argv. An
	// argument vector is recorded only when the source supplied a real one.
	argv_start := u32(len(sink.payloads.arguments))
	argv_count := u32(0)
	if arguments, has_argv := object["argv"]; has_argv {
		if array, is_array := arguments.(json.Array); is_array {
			for element in array {
				text, is_text := element.(json.String)
				if !is_text {
					continue
				}
				append(&sink.payloads.arguments, api.intern_text(sink, string(text)))
				argv_count += 1
			}
		}
	}

	payload := model.add_command(
		&sink.payloads,
		model.Command_Payload {
			command = command,
			command_line = api.intern_text(sink, line),
			argv_start = argv_start,
			argv_count = argv_count,
			has_argv = argv_count > 0,
			exit_code = i32(exit_code),
			status = status,
		},
	)

	duration, has_duration := integer_field(object, "duration_ns")

	input := base_input(state, object, .Command_Start, "command")
	input.actor = state.agent
	input.primary = command
	input.span = span
	input.summary = line
	input.payload = payload
	input.duration_ns = duration
	input.has_duration = has_duration
	start := api.add_event(sink, input)

	// docs/05 requires command output to stay separate from application
	// diagnostics, so output is its own event rather than being folded into
	// the diagnostics stream.
	if output, has_output := string_field(object, "output"); has_output && output != "" {
		api.declare_capability(sink, .Command_Output)
		output_input := base_input(state, object, .Command_Output, "command")
		output_input.actor = state.agent
		output_input.primary = command
		output_input.span = span
		output_input.summary = "output"
		api.add_event(sink, output_input)
	}

	if has_exit {
		end_input := base_input(state, object, .Command_End, "command")
		end_input.actor = state.agent
		end_input.primary = command
		end_input.span = span
		end_input.summary = line
		end_input.payload = payload
		api.add_event(sink, end_input)
		api.close_span(sink, span, start)
	} else {
		// docs/03: a span that simply stops is not given a synthetic successful end.
		api.note_warning(sink, .Span_Incomplete)
	}
}

@(private)
import_diagnostic :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink

	message, _ := string_field(object, "message")
	severity_text, _ := string_field(object, "severity")

	severity: model.Severity
	switch severity_text {
	case "error": severity = .Error
	case "warning": severity = .Warning
	case "info": severity = .Info
	case "hint": severity = .Note
	case: severity = .Unknown
	}

	path_entity := model.NO_ENTITY
	if raw_path, has_path := string_field(object, "path"); has_path {
		path, rejection := core.normalize_path(raw_path, context.temp_allocator)
		if rejection == .None {
			path_entity = api.add_entity(sink, .Path, path, "")
		} else {
			api.note_warning(sink, .Path_Rejected)
		}
	}

	line, _ := integer_field(object, "line")
	column, _ := integer_field(object, "column")
	code, _ := string_field(object, "code")

	payload := model.add_diagnostic(
		&sink.payloads,
		model.Diagnostic_Payload {
			severity = severity,
			path = path_entity,
			line = u32(line),
			column = u32(column),
			code = api.intern_text(sink, code),
			message = api.intern_text(sink, message),
		},
	)

	input := base_input(state, object, .Diagnostic, "diagnostic")
	input.actor = state.agent
	input.primary = path_entity
	input.summary = message
	input.payload = payload
	api.add_event(sink, input)
}

@(private)
import_test :: proc(state: ^Import_State, object: json.Object) {
	sink := state.sink
	api.declare_capability(sink, .Structured_Tests)

	name, _ := string_field(object, "name")
	if name == "" {
		api.note_warning(sink, .Malformed_Record)
		api.note_ignored(sink)
		return
	}

	suite_name, _ := string_field(object, "suite")

	// docs/06: comparability rests on a stable test identity, established here
	// at import rather than by string comparison at analysis time.
	test_case := api.add_entity(sink, .Test_Case, name, suite_name)
	suite := model.NO_ENTITY
	if suite_name != "" {
		suite = api.add_entity(sink, .Test_Suite, suite_name, "")
	}

	status_text, _ := string_field(object, "status")
	status: model.Outcome_Status
	switch status_text {
	case "pass": status = .Passed
	case "fail": status = .Failed
	case "skip": status = .Skipped
	case "error": status = .Errored
	case:
		status = .Unknown
		api.note_warning(sink, .Unsupported_Record)
	}

	message, _ := string_field(object, "message")

	path_entity := model.NO_ENTITY
	if raw_path, has_path := string_field(object, "path"); has_path {
		path, rejection := core.normalize_path(raw_path, context.temp_allocator)
		if rejection == .None {
			path_entity = api.add_entity(sink, .Path, path, "")
		} else {
			api.note_warning(sink, .Path_Rejected)
		}
	}

	line, _ := integer_field(object, "line")

	payload := model.add_test(
		&sink.payloads,
		model.Test_Payload {
			test_case = test_case,
			suite = suite,
			status = status,
			message = api.intern_text(sink, message),
			path = path_entity,
			line = u32(line),
		},
	)

	input := base_input(state, object, .Test_Case_Result, "test")
	input.actor = state.agent
	input.primary = test_case
	input.summary = name
	input.payload = payload
	api.add_event(sink, input)
}

// import_unknown retains a record whose type this adapter does not map.
//
// docs/05 requirement 9: unknown record types are retained as extension events
// or the reason they were ignored is reported. Retaining is better: a future
// version of Norn can interpret what this one could not.
@(private)
import_unknown :: proc(state: ^Import_State, kind: string, record: string) {
	sink := state.sink
	api.note_warning(sink, .Unsupported_Record)

	blob := api.add_blob_text(sink, record)
	_ = blob

	input := api.Event_Input {
		kind = .Extension_Event,
		summary = kind,
		source_type = kind,
		record_number = state.record_number,
		byte_offset = state.byte_offset,
	}

	// The envelope timestamp is still honoured, so an extension event sits in
	// the right place on the timeline even though its body is uninterpreted.
	value, parse_err := json.parse_string(record, allocator = context.temp_allocator)
	if parse_err == nil {
		if object, is_object := value.(json.Object); is_object {
			input.wall_time_ns, input.has_wall_time = timing(object)
		}
	}

	api.add_event(sink, input)
}

// SUMMARY_LENGTH bounds a generated timeline label.
//
// Long enough to identify a message, short enough that the string table is not
// filled with whole conversations.
SUMMARY_LENGTH :: 80

@(private)
summarize :: proc(text: string) -> string {
	// The first line, because a summary spanning lines renders as one run-on
	// label in the timeline.
	end := len(text)
	for index in 0 ..< len(text) {
		if text[index] == '\n' || text[index] == '\r' {
			end = index
			break
		}
	}
	if end > SUMMARY_LENGTH {
		end = SUMMARY_LENGTH
		// Never split a UTF-8 sequence: a truncated label must still be text.
		for end > 0 && (text[end] & 0xC0) == 0x80 {
			end -= 1
		}
	}
	return text[:end]
}

// json_content renders a field for storage, reporting whether it was structured.
//
// docs/03: tool arguments and results are structured blobs when valid JSON and
// opaque text otherwise. Recording which lets a viewer avoid parsing text that
// was never JSON.
@(private)
json_content :: proc(object: json.Object, key: string) -> (content: string, structured: bool) {
	value, present := object[key]
	if !present {
		return "", false
	}

	#partial switch typed in value {
	case json.String:
		return string(typed), false
	}

	text, err := json.unparse(value, allocator = context.temp_allocator)
	if err != nil {
		return "", false
	}
	return text, true
}

@(private)
string_field :: proc(object: json.Object, key: string) -> (value: string, present: bool) {
	raw, has := object[key]
	if !has {
		return "", false
	}
	text, is_text := raw.(json.String)
	if !is_text {
		return "", false
	}
	return string(text), true
}

@(private)
integer_field :: proc(object: json.Object, key: string) -> (value: i64, present: bool) {
	raw, has := object[key]
	if !has {
		return 0, false
	}
	#partial switch typed in raw {
	case json.Integer:
		return i64(typed), true
	case json.Float:
		return i64(typed), true
	}
	return 0, false
}

@(private)
boolean_field :: proc(object: json.Object, key: string) -> (value: bool, present: bool) {
	raw, has := object[key]
	if !has {
		return false, false
	}
	flag, is_bool := raw.(json.Boolean)
	if !is_bool {
		return false, false
	}
	return bool(flag), true
}

// next_record returns the next non-blank line, advancing `rest`.
//
// One line at a time is what keeps the parser streaming: each record is parsed
// and released independently, so memory is bounded by the longest record rather
// than by the file.
@(private)
next_record :: proc(rest: ^string) -> (record: string, ok: bool) {
	for len(rest^) > 0 {
		line: string
		newline := strings.index_byte(rest^, '\n')
		if newline < 0 {
			line = rest^
			rest^ = ""
		} else {
			line = rest^[:newline]
			rest^ = rest^[newline + 1:]
		}

		line = strings.trim_right(line, "\r")
		if strings.trim_space(line) == "" {
			continue
		}
		return line, true
	}
	return "", false
}

@(private)
first_line :: proc(text: string) -> (line: string, ok: bool) {
	rest := text
	return next_record(&rest)
}
