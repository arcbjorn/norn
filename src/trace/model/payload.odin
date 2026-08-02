package model

// Kind-specific event payloads.
//
// docs/03-trace-model.md: the envelope stays compact and fixed-width, and
// kind-specific payloads live in typed column groups rather than a union large
// enough for every event. An Event names its payload with a Payload_Ref, whose
// `group` selects one of the tables below and whose `index` is the row.
//
// Only kinds that analysis or the viewer must interpret get a payload group.
// Everything else is adequately described by its envelope and summary string,
// and inventing a group for it would cost bytes in every trace to carry
// nothing a reader consults.

// Payload_Group discriminates the typed payload tables. Values are on-disk and
// are appended, never renumbered. Zero means the event has no payload.
Payload_Group :: enum u16 {
	None       = 0,
	Diagnostic = 1,
	Command    = 2,
	Test_Case  = 3,
	Message    = 4,
	Tool       = 5,
}

// Diagnostic_Payload carries a compiler or linter message.
//
// docs/03: diagnostics have severity and optional path, line, column, symbol,
// and code. The path is an entity rather than a string so that a diagnostic
// and a mutation naming the same file are recognizably about one subject —
// which is exactly what the "diagnostic directly names edited path" scoring
// signal depends on.
//
// Line and column are one-based, matching how every compiler reports them.
// Zero means absent, which is unambiguous because there is no line zero.
Diagnostic_Payload :: struct {
	severity: Severity,
	path:     Entity_Id,
	symbol:   Entity_Id,
	line:     u32,
	column:   u32,
	// End line for a multi-line span; zero when the diagnostic names one line.
	end_line: u32,
	// Machine-readable code such as an error number, when the tool emits one.
	code:    String_Id,
	message: String_Id,
}

// has_location reports whether the diagnostic names a specific line, which
// determines whether hunk-overlap scoring can apply.
diagnostic_has_location :: proc "contextless" (payload: Diagnostic_Payload) -> bool {
	return payload.path != NO_ENTITY && payload.line != 0
}

// covers_line reports whether the diagnostic's span includes `line`.
diagnostic_covers_line :: proc "contextless" (payload: Diagnostic_Payload, line: u32) -> bool {
	if payload.line == 0 {
		return false
	}
	last := payload.end_line if payload.end_line >= payload.line else payload.line
	return line >= payload.line && line <= last
}

// Command_Payload describes a process invocation.
//
// docs/03: commands store an argument vector when the source provides one, and
// a shell command string remains text and is never parsed as if it were a
// trustworthy argv. Both fields exist so neither has to masquerade as the
// other: `argv_*` is populated only when the provider gave a real vector.
Command_Payload :: struct {
	// The command entity, so repeated invocations of one command are
	// recognizably the same subject.
	command: Entity_Id,
	// Working directory as a repository-relative path entity, when inside the
	// repository. NO_ENTITY when the command ran elsewhere.
	working_directory: Entity_Id,
	// Raw command line as recorded. Display only; never parsed into argv.
	command_line: String_Id,
	// Index and count into the argument table, when a real argv was recorded.
	argv_start: u32,
	argv_count: u32,
	exit_code:  i32,
	status:     Outcome_Status,
	// True when the provider supplied a structured argument vector rather than
	// only a shell string.
	has_argv: bool,
}

// Test_Payload describes one test case result or run.
//
// `identity` is the stable test identity docs/06 requires for comparability:
// two outcomes are comparable when they have the same stable test identity.
// It is an entity so that identity is established once, at import, rather than
// by string comparison at analysis time.
Test_Payload :: struct {
	test_case: Entity_Id,
	suite:     Entity_Id,
	// The command entity that produced this result, linking a test back to the
	// invocation that ran it.
	command:  Entity_Id,
	status:   Outcome_Status,
	// Failure detail, when the runner reported one.
	message: String_Id,
	// Location the runner attributed the failure to, when it gave one.
	path: Entity_Id,
	line: u32,
}

// Message_Payload carries visible conversation text.
//
// docs/03: conversation events contain visible text supplied by the trace, and
// Norn does not invent or infer hidden reasoning events. `text` is therefore
// whatever the provider recorded as visible, nothing more.
Message_Payload :: struct {
	// Full text as a blob, because messages routinely exceed what belongs in
	// the string table.
	text: Blob_Id,
	// Short summary for timeline display, interned because it is shown often.
	summary: String_Id,
	// The model or provider entity that produced an agent message.
	model: Entity_Id,
	// True when the importer classified this message as stating a goal, which
	// attempt detection uses as a boundary.
	goal_bearing: bool,
}

// Tool_Payload describes a tool call, result, or error.
//
// docs/03: tool arguments and results are structured blobs when valid JSON and
// opaque text otherwise. `structured` records which, so a viewer does not
// attempt to parse text that was never JSON.
Tool_Payload :: struct {
	tool: Entity_Id,
	// Provider's own call identifier, used to pair a result with its call.
	call_id: String_Id,
	// Arguments for a call, or the payload for a result or error.
	content:    Blob_Id,
	structured: bool,
	status:     Outcome_Status,
	// Error text for a tool error, separate from content so a failed call can
	// retain both what it was asked to do and why it failed.
	error_message: String_Id,
}

// Payload_Tables holds every typed payload group for one trace.
//
// Rows are appended in event order within each group, so a group's rows are
// naturally sorted by the sequence of the events that reference them.
Payload_Tables :: struct {
	diagnostics: [dynamic]Diagnostic_Payload,
	commands:    [dynamic]Command_Payload,
	tests:       [dynamic]Test_Payload,
	messages:    [dynamic]Message_Payload,
	tools:       [dynamic]Tool_Payload,
	// Flattened argument vectors referenced by Command_Payload.
	arguments: [dynamic]String_Id,
}

payload_tables_init :: proc(tables: ^Payload_Tables, allocator := context.allocator) {
	tables.diagnostics = make([dynamic]Diagnostic_Payload, 0, 16, allocator)
	tables.commands = make([dynamic]Command_Payload, 0, 16, allocator)
	tables.tests = make([dynamic]Test_Payload, 0, 16, allocator)
	tables.messages = make([dynamic]Message_Payload, 0, 16, allocator)
	tables.tools = make([dynamic]Tool_Payload, 0, 16, allocator)
	tables.arguments = make([dynamic]String_Id, 0, 32, allocator)
}

payload_tables_destroy :: proc(tables: ^Payload_Tables) {
	delete(tables.diagnostics)
	delete(tables.commands)
	delete(tables.tests)
	delete(tables.messages)
	delete(tables.tools)
	delete(tables.arguments)
	tables^ = {}
}

// add_diagnostic appends a diagnostic payload and returns its reference.
add_diagnostic :: proc(
	tables: ^Payload_Tables,
	payload: Diagnostic_Payload,
) -> Payload_Ref {
	index := u32(len(tables.diagnostics))
	append(&tables.diagnostics, payload)
	return Payload_Ref{group = u16(Payload_Group.Diagnostic), index = index}
}

add_command :: proc(tables: ^Payload_Tables, payload: Command_Payload) -> Payload_Ref {
	index := u32(len(tables.commands))
	append(&tables.commands, payload)
	return Payload_Ref{group = u16(Payload_Group.Command), index = index}
}

add_test :: proc(tables: ^Payload_Tables, payload: Test_Payload) -> Payload_Ref {
	index := u32(len(tables.tests))
	append(&tables.tests, payload)
	return Payload_Ref{group = u16(Payload_Group.Test_Case), index = index}
}

add_message :: proc(tables: ^Payload_Tables, payload: Message_Payload) -> Payload_Ref {
	index := u32(len(tables.messages))
	append(&tables.messages, payload)
	return Payload_Ref{group = u16(Payload_Group.Message), index = index}
}

add_tool :: proc(tables: ^Payload_Tables, payload: Tool_Payload) -> Payload_Ref {
	index := u32(len(tables.tools))
	append(&tables.tools, payload)
	return Payload_Ref{group = u16(Payload_Group.Tool), index = index}
}

// add_arguments appends an argument vector and returns its start and count.
add_arguments :: proc(
	tables: ^Payload_Tables,
	arguments: []String_Id,
) -> (
	start: u32,
	count: u32,
) {
	start = u32(len(tables.arguments))
	append(&tables.arguments, ..arguments)
	return start, u32(len(arguments))
}

// Accessors return the payload for an event when it belongs to that group.
//
// Each returns false rather than a zero value for a mismatched group, so a
// caller cannot silently treat a command as a diagnostic and read meaningless
// fields.

get_diagnostic :: proc(
	tables: ^Payload_Tables,
	ref: Payload_Ref,
) -> (
	payload: Diagnostic_Payload,
	ok: bool,
) {
	if Payload_Group(ref.group) != .Diagnostic || int(ref.index) >= len(tables.diagnostics) {
		return {}, false
	}
	return tables.diagnostics[ref.index], true
}

get_command :: proc(
	tables: ^Payload_Tables,
	ref: Payload_Ref,
) -> (
	payload: Command_Payload,
	ok: bool,
) {
	if Payload_Group(ref.group) != .Command || int(ref.index) >= len(tables.commands) {
		return {}, false
	}
	return tables.commands[ref.index], true
}

get_test :: proc(
	tables: ^Payload_Tables,
	ref: Payload_Ref,
) -> (
	payload: Test_Payload,
	ok: bool,
) {
	if Payload_Group(ref.group) != .Test_Case || int(ref.index) >= len(tables.tests) {
		return {}, false
	}
	return tables.tests[ref.index], true
}

get_message :: proc(
	tables: ^Payload_Tables,
	ref: Payload_Ref,
) -> (
	payload: Message_Payload,
	ok: bool,
) {
	if Payload_Group(ref.group) != .Message || int(ref.index) >= len(tables.messages) {
		return {}, false
	}
	return tables.messages[ref.index], true
}

get_tool :: proc(
	tables: ^Payload_Tables,
	ref: Payload_Ref,
) -> (
	payload: Tool_Payload,
	ok: bool,
) {
	if Payload_Group(ref.group) != .Tool || int(ref.index) >= len(tables.tools) {
		return {}, false
	}
	return tables.tools[ref.index], true
}

// command_arguments returns the argument vector for a command payload.
//
// The result borrows the table and is empty when the provider supplied only a
// shell string, which callers must distinguish from a command with no
// arguments: the former means "unknown", the latter means "none".
command_arguments :: proc(
	tables: ^Payload_Tables,
	payload: Command_Payload,
) -> []String_Id {
	if !payload.has_argv {
		return nil
	}
	start := int(payload.argv_start)
	count := int(payload.argv_count)
	if start < 0 || count < 0 || start + count > len(tables.arguments) {
		return nil
	}
	return tables.arguments[start:start + count]
}
