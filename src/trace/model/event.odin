package model

// Canonical events.
//
// docs/03-trace-model.md defines the event envelope and kinds. The envelope is
// compact and fixed-width: kind-specific data lives in typed payload columns
// rather than a union sized for the largest event, because the timeline reads
// envelopes for hundreds of thousands of events while touching payloads for
// only the few that are visible or selected.

// Event_Kind enumerates canonical semantics. Numeric values are part of the
// on-disk format: append new kinds, never renumber existing ones.
//
// A provider record with no canonical mapping becomes Extension_Event, which
// retains a namespaced type and raw payload but must not influence core
// behavior unless an analysis explicitly understands the namespace.
Event_Kind :: enum u16 {
	Unknown = 0,

	// Session lifecycle.
	Session_Start = 1,
	Session_End   = 2,
	Phase_Start   = 3,
	Phase_End     = 4,
	Checkpoint    = 5,

	// Conversation. Visible text only; Norn never invents reasoning events.
	User_Message   = 16,
	Agent_Message  = 17,
	System_Message = 18,
	Summary        = 19,

	// Tools.
	Tool_Call   = 32,
	Tool_Result = 33,
	Tool_Error  = 34,

	// Repository activity.
	File_Read          = 48,
	File_Create        = 49,
	File_Modify        = 50,
	File_Delete        = 51,
	File_Rename        = 52,
	Directory_Observe  = 53,

	// Processes.
	Command_Start  = 64,
	Command_Output = 65,
	Command_End    = 66,
	Process_Spawn  = 67,
	Process_Exit   = 68,

	// Outcomes.
	Test_Run_Start   = 80,
	Test_Case_Result = 81,
	Test_Run_End     = 82,
	Diagnostic       = 83,
	Build_Result     = 84,
	Lint_Result      = 85,
	Explicit_Error   = 86,

	// Control and accounting.
	Retry            = 96,
	Approval_Request = 97,
	Approval_Result  = 98,
	Token_Usage      = 99,
	Rate_Limit       = 100,
	Provider_Switch  = 101,
	Annotation       = 102,

	// Provider records with no canonical semantic mapping.
	Extension_Event = 4096,
}

// is_mutation reports whether a kind changes repository content. Replay
// consumes exactly these kinds.
is_mutation :: proc "contextless" (kind: Event_Kind) -> bool {
	#partial switch kind {
	case .File_Create, .File_Modify, .File_Delete, .File_Rename:
		return true
	}
	return false
}

// is_outcome reports whether a kind can be selected as the starting point of
// an evidence stack. docs/01: commands, test runs, diagnostics, and explicit
// errors are outcomes.
is_outcome :: proc "contextless" (kind: Event_Kind) -> bool {
	#partial switch kind {
	case .Command_End,
	     .Test_Run_End,
	     .Test_Case_Result,
	     .Diagnostic,
	     .Build_Result,
	     .Lint_Result,
	     .Explicit_Error:
		return true
	}
	return false
}

// is_conversation reports whether a kind carries visible message text.
is_conversation :: proc "contextless" (kind: Event_Kind) -> bool {
	#partial switch kind {
	case .User_Message, .Agent_Message, .System_Message, .Summary:
		return true
	}
	return false
}

// Time_Quality records how much a timestamp can be trusted. docs/03: importers
// repair non-monotonic timestamps by preserving source order and recording a
// warning; they never silently reorder mutations.
Time_Quality :: enum u8 {
	Unknown  = 0, // No usable timestamp.
	Exact    = 1, // Taken directly from the source record.
	Derived  = 2, // Computed from another trustworthy source field.
	Repaired = 3, // Adjusted to preserve monotonicity; see import warnings.
}

// Event_Flag marks envelope-level properties that the timeline reads without
// consulting a payload.
Event_Flag :: enum u8 {
	Has_Wall_Time        = 0,
	Has_Monotonic_Offset = 1,
	Has_Duration         = 2,
	Redacted             = 3, // Some field was replaced by a redaction marker.
	Truncated            = 4, // Source content exceeded a retention limit.
	Synthetic            = 5, // Produced by the importer, not a source record.
	Span_Incomplete      = 6, // Span opened here never received an end.
	Bookmarked           = 7, // Reserved for overlay-driven display.
}

Event_Flags :: bit_set[Event_Flag; u8]

// Payload_Ref locates kind-specific data in a payload column group. A zero
// group with zero index means the event has no payload beyond its envelope.
Payload_Ref :: struct {
	group: u16, // Payload_Group discriminant.
	index: u32, // Row within that group.
}

NO_PAYLOAD :: Payload_Ref{}

// Event is the canonical envelope. Field order groups hot timeline fields
// first; the codec stores these as separate columns regardless.
//
// Optional integer fields are meaningful only when the corresponding flag is
// set. A zero wall_time_ns is a real instant (the Unix epoch), so absence must
// be carried by the flag rather than by a sentinel value.
Event :: struct {
	id:                   Event_Id,
	sequence:             Sequence,
	kind:                 Event_Kind,
	flags:                Event_Flags,
	time_quality:         Time_Quality,
	wall_time_ns:         i64,
	monotonic_offset_ns:  i64,
	duration_ns:          i64,
	parent_span_id:       Span_Id,
	actor_entity_id:      Entity_Id,
	primary_entity_id:    Entity_Id,
	summary_string_id:    String_Id,
	payload:              Payload_Ref,
	source:               Source_Ref,
}

// has_wall_time reports whether the event's wall clock field is meaningful.
has_wall_time :: proc "contextless" (event: Event) -> bool {
	return .Has_Wall_Time in event.flags
}

// has_duration reports whether the event's duration field is meaningful.
has_duration :: proc "contextless" (event: Event) -> bool {
	return .Has_Duration in event.flags
}

// Source_Ref is the provenance record required by docs/03 for auditability and
// importer debugging. Every canonical event points to the source material it
// came from, even when the raw record itself was not retained.
Source_Ref :: struct {
	importer_id:      String_Id, // Adapter identity, e.g. "codex".
	importer_version: String_Id, // Semantic version of that adapter.
	source_file:      String_Id, // Redacted source file identity.
	source_type:      String_Id, // Provider's own name for the record type.
	record_number:    u64,       // Ordinal within the source file.
	byte_offset:      u64,       // Byte offset of the record, when known.
	raw_blob:         Blob_Id,   // Retained redacted record; NO_BLOB when off.
	transforms:       Transform_Flags,
}

// Transform records a normalization applied between source and canonical
// record. The import report counts these, and the inspector shows them so a
// surprising value can be traced to the step that produced it.
Transform :: enum u8 {
	Redacted           = 0,
	Timestamp_Repaired = 1,
	Path_Normalized    = 2,
	Content_Truncated  = 3,
	Encoding_Repaired  = 4,
	Order_Preserved    = 5, // Source order kept over a contradictory timestamp.
}

Transform_Flags :: bit_set[Transform; u8]
