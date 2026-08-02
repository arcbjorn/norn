package test_analysis

import "src:trace/codec"
import "src:trace/model"

// Scaffolding for analysis tests.
//
// Analysis reads a codec.Trace, so tests build one in memory rather than
// through a file. The builder mirrors what an importer would produce, which
// keeps the tests honest about what analysis is allowed to assume.

Builder :: struct {
	trace:         codec.Trace,
	next_event:    model.Event_Id,
	next_sequence: model.Sequence,
	next_entity:   model.Entity_Id,
	next_span:     model.Span_Id,
	clock_ns:      i64,
}

builder_init :: proc(builder: ^Builder) {
	model.string_table_init(&builder.trace.strings)
	model.blob_table_init(&builder.trace.blobs)
	model.payload_tables_init(&builder.trace.payloads)
	builder.trace.entities = make([dynamic]model.Entity, 0, 8)
	builder.trace.spans = make([dynamic]model.Span, 0, 4)
	builder.trace.events = make([dynamic]model.Event, 0, 16)
	builder.trace.edges = make([dynamic]model.Edge, 0, 8)
	builder.trace.mutations = make([dynamic]model.Mutation, 0, 8)
	builder.trace.directory = make([dynamic]codec.Directory_Entry, 0, 4)

	builder.next_event = 1
	builder.next_sequence = 1
	builder.next_entity = 1
	builder.next_span = 1
	builder.clock_ns = 1_700_000_000_000_000_000
}

builder_destroy :: proc(builder: ^Builder) {
	codec.trace_destroy(&builder.trace)
}

intern :: proc(builder: ^Builder, value: string) -> model.String_Id {
	id, _ := model.string_intern(&builder.trace.strings, value)
	return id
}

// add_entity registers a subject and returns its identifier.
add_entity :: proc(
	builder: ^Builder,
	kind: model.Entity_Kind,
	name: string,
	qualifier: string = "",
) -> model.Entity_Id {
	id := builder.next_entity
	builder.next_entity += 1
	append(
		&builder.trace.entities,
		model.Entity {
			id = id,
			kind = kind,
			name = intern(builder, name),
			qualifier = intern(builder, qualifier),
		},
	)
	return id
}

add_span :: proc(builder: ^Builder, kind: model.Span_Kind) -> model.Span_Id {
	id := builder.next_span
	builder.next_span += 1
	append(
		&builder.trace.spans,
		model.Span{id = id, kind = kind, start_sequence = builder.next_sequence},
	)
	return id
}

@(private)
push_event :: proc(
	builder: ^Builder,
	kind: model.Event_Kind,
	span: model.Span_Id = model.NO_SPAN,
	primary: model.Entity_Id = model.NO_ENTITY,
	payload: model.Payload_Ref = model.NO_PAYLOAD,
	summary: string = "",
) -> model.Event_Id {
	id := builder.next_event
	builder.next_event += 1

	append(
		&builder.trace.events,
		model.Event {
			id = id,
			sequence = builder.next_sequence,
			kind = kind,
			flags = {.Has_Wall_Time},
			time_quality = .Exact,
			wall_time_ns = builder.clock_ns,
			parent_span_id = span,
			primary_entity_id = primary,
			summary_string_id = intern(builder, summary),
			payload = payload,
		},
	)
	builder.next_sequence += 1
	builder.clock_ns += 1_000_000_000
	return id
}

// advance_clock moves time forward without emitting an event, for testing the
// inactivity boundary.
advance_clock :: proc(builder: ^Builder, nanoseconds: i64) {
	builder.clock_ns += nanoseconds
}

// add_message records a conversation event, optionally goal-bearing.
add_message :: proc(
	builder: ^Builder,
	kind: model.Event_Kind,
	text: string,
	goal_bearing := false,
) -> model.Event_Id {
	payload := model.add_message(
		&builder.trace.payloads,
		model.Message_Payload{summary = intern(builder, text), goal_bearing = goal_bearing},
	)
	return push_event(builder, kind, payload = payload, summary = text)
}

// add_mutation records a file change with an optional patch.
add_mutation :: proc(
	builder: ^Builder,
	path: model.Entity_Id,
	span: model.Span_Id = model.NO_SPAN,
	patch_text: string = "",
	status := model.Replay_Status.Verified,
) -> model.Event_Id {
	event := push_event(builder, .File_Modify, span = span, primary = path)

	mutation := model.Mutation {
		event_id = event,
		path     = path,
		op       = .Modify,
		encoding = .Utf8,
		status   = status,
	}
	if patch_text != "" {
		blob, _ := model.blob_add(&builder.trace.blobs, transmute([]byte)patch_text)
		mutation.patch_blob = blob
		mutation.flags += {.Has_Patch}
	}
	append(&builder.trace.mutations, mutation)
	return event
}

// add_event_of_kind records a bare event naming a subject.
add_event_of_kind :: proc(
	builder: ^Builder,
	kind: model.Event_Kind,
	primary: model.Entity_Id,
) -> model.Event_Id {
	return push_event(builder, kind, primary = primary)
}

// add_diagnostic records a compiler or linter message naming a location.
add_diagnostic :: proc(
	builder: ^Builder,
	path: model.Entity_Id,
	line: u32,
	message: string,
	span: model.Span_Id = model.NO_SPAN,
	severity := model.Severity.Error,
) -> model.Event_Id {
	payload := model.add_diagnostic(
		&builder.trace.payloads,
		model.Diagnostic_Payload {
			severity = severity,
			path = path,
			line = line,
			message = intern(builder, message),
		},
	)
	return push_event(builder, .Diagnostic, span = span, primary = path, payload = payload)
}

// add_test_result records a structured test outcome.
add_test_result :: proc(
	builder: ^Builder,
	test_case: model.Entity_Id,
	status: model.Outcome_Status,
	span: model.Span_Id = model.NO_SPAN,
	suite: model.Entity_Id = model.NO_ENTITY,
	path: model.Entity_Id = model.NO_ENTITY,
	line: u32 = 0,
) -> model.Event_Id {
	payload := model.add_test(
		&builder.trace.payloads,
		model.Test_Payload {
			test_case = test_case,
			suite = suite,
			status = status,
			path = path,
			line = line,
		},
	)
	return push_event(
		builder,
		.Test_Case_Result,
		span = span,
		primary = test_case,
		payload = payload,
	)
}

// add_command_end records a command outcome with an optional argument vector.
add_command_end :: proc(
	builder: ^Builder,
	command: model.Entity_Id,
	status: model.Outcome_Status,
	span: model.Span_Id = model.NO_SPAN,
	arguments: []string = nil,
	kind := model.Event_Kind.Command_End,
	structured := false,
) -> model.Event_Id {
	payload := model.Command_Payload {
		command = command,
		status  = status,
	}
	if arguments != nil {
		ids := make([]model.String_Id, len(arguments), context.temp_allocator)
		defer delete(ids, context.temp_allocator)
		for argument, index in arguments {
			ids[index] = intern(builder, argument)
		}
		start, count := model.add_arguments(&builder.trace.payloads, ids)
		payload.argv_start = start
		payload.argv_count = count
		payload.has_argv = true
	}
	_ = structured

	ref := model.add_command(&builder.trace.payloads, payload)
	return push_event(builder, kind, span = span, primary = command, payload = ref)
}

// add_tool_error records a failing tool call with a message.
add_tool_error :: proc(builder: ^Builder, tool: model.Entity_Id, message: string) -> model.Event_Id {
	payload := model.add_tool(
		&builder.trace.payloads,
		model.Tool_Payload {
			tool = tool,
			status = .Errored,
			error_message = intern(builder, message),
		},
	)
	return push_event(builder, .Tool_Error, primary = tool, payload = payload, summary = message)
}

// add_tests_edge records an explicit test-to-file relationship.
add_tests_edge :: proc(builder: ^Builder, test_case: model.Entity_Id, path: model.Entity_Id) {
	append(
		&builder.trace.edges,
		model.Edge {
			kind = .Tests,
			origin = .Explicit,
			from = model.entity_endpoint(test_case),
			to = model.entity_endpoint(path),
			confidence = model.CONFIDENCE_SCALE,
		},
	)
}

// close_span records the end of a span so its bounds are complete.
close_span :: proc(builder: ^Builder, span: model.Span_Id, start_event: model.Event_Id) {
	index := int(span) - 1
	if index < 0 || index >= len(builder.trace.spans) {
		return
	}
	builder.trace.spans[index].start_event = start_event
	builder.trace.spans[index].end_sequence = builder.next_sequence
}
