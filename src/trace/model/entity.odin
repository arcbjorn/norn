package model

// Entities and spans.
//
// docs/03-trace-model.md: entities give events stable subjects and are
// immutable descriptions. Anything that varies over time is an event, not an
// entity field. This is what lets the repository map and the timeline stay
// consistent: a path entity never changes, so a selection can name it without
// also naming a moment.

// Entity_Kind enumerates the subjects an event can be about. Numeric values
// are part of the on-disk format.
Entity_Kind :: enum u16 {
	Unknown = 0,

	// Actors.
	Actor_User      = 1,
	Actor_Agent     = 2,
	Actor_Sub_Agent = 3,
	Actor_Tool      = 4,
	Actor_Process   = 5,

	Repository = 16,
	Path       = 17,
	Symbol     = 18,
	Command    = 19,
	Test_Case  = 20,
	Test_Suite = 21,
	Diagnostic = 22,
	Model      = 23,
	Provider   = 24,
	External   = 25, // External resource such as a URL host.
}

// is_actor reports whether a kind can appear as an event's actor.
is_actor :: proc "contextless" (kind: Entity_Kind) -> bool {
	#partial switch kind {
	case .Actor_User, .Actor_Agent, .Actor_Sub_Agent, .Actor_Tool, .Actor_Process:
		return true
	}
	return false
}

// Entity is an immutable description of a subject.
//
// `name` is the display name. `qualifier` disambiguates entities that share a
// name: the suite for a test case, the directory for a symbol, the provider
// for a model. `parent` links a symbol to its file or a test case to its
// suite, and is NO_ENTITY otherwise.
Entity :: struct {
	id:        Entity_Id,
	kind:      Entity_Kind,
	name:      String_Id,
	qualifier: String_Id,
	parent:    Entity_Id,

	// First and last sequence at which this entity was observed. These are
	// derived from events and exist so the repository map can filter by time
	// without scanning every event.
	first_seen: Sequence,
	last_seen:  Sequence,
}

// Span groups events belonging to one operation or turn.
//
// docs/03: spans may nest but may not form cycles. Incomplete spans are valid
// and flagged; import must not synthesize a successful end for a span that
// simply stops.
Span_Kind :: enum u16 {
	Unknown = 0,

	Agent_Turn       = 1,
	Tool_Invocation  = 2,
	Command_Execution = 3,
	Test_Run         = 4,
	Edit_Transaction = 5, // Importer-recovered group of related mutations.
	Phase            = 6,
}

Span_Flag :: enum u8 {
	Incomplete = 0, // No end record was observed in the source.
	Synthetic  = 1, // Reconstructed by the importer, not explicit in source.
	Failed     = 2, // Ended in a recorded failure.
}

Span_Flags :: bit_set[Span_Flag; u8]

Span :: struct {
	id:            Span_Id,
	kind:          Span_Kind,
	flags:         Span_Flags,
	parent:        Span_Id,
	name:          String_Id,
	start_sequence: Sequence,
	end_sequence:   Sequence, // Equals start_sequence when Incomplete is set.
	start_event:    Event_Id,
	end_event:      Event_Id, // NO_EVENT when Incomplete is set.
}

// is_complete reports whether the span observed an explicit end.
is_complete :: proc "contextless" (span: Span) -> bool {
	return .Incomplete not_in span.flags
}
