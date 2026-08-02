package model

// Edges between events and entities.
//
// docs/03-trace-model.md and decision 008: an edge always records how it came
// to exist. The product promise is that a user can distinguish a recorded fact
// from a derived guess, so Edge_Origin is not optional metadata — it is the
// field that makes the rest of the edge safe to display.

// Edge_Kind enumerates relationship semantics. Numeric values are on-disk.
Edge_Kind :: enum u16 {
	Unknown = 0,

	Parent                = 1,  // Explicit structural parent.
	Result_Of             = 2,  // Result produced by a recorded invocation.
	Reads                 = 3,  // Event observed an entity.
	Writes                = 4,  // Event mutated an entity.
	Renames               = 5,  // Path identity moved.
	Diagnoses             = 6,  // Diagnostic refers to a path or symbol.
	Tests                 = 7,  // Test outcome exercises a known entity.
	Precedes              = 8,  // Ordered relationship used for navigation.
	Candidate_Contributor = 9,  // Derived evidence-based relationship.
	Supersedes            = 10, // Later record replaces an earlier reading.
}

// Edge_Origin is the evidence level. docs/06 requires the UI to identify this
// for every relationship it shows.
Edge_Origin :: enum u8 {
	// Present in source data. The provider stated this relationship.
	Explicit = 0,
	// Mechanically derived from spans or mutation data. Follows
	// deterministically from canonical facts.
	Reconstructed = 1,
	// Produced by an analysis rule. A ranked hypothesis, not a fact.
	Inferred = 2,
}

// origin_name returns a stable identifier for reports, tests, and UI labels.
origin_name :: proc "contextless" (origin: Edge_Origin) -> string {
	switch origin {
	case .Explicit:      return "explicit"
	case .Reconstructed: return "reconstructed"
	case .Inferred:      return "inferred"
	}
	return "unknown"
}

// Endpoint_Kind discriminates what an edge endpoint refers to. An edge may
// connect two events, two entities, or an event and an entity.
Endpoint_Kind :: enum u8 {
	Event  = 0,
	Entity = 1,
}

Endpoint :: struct {
	kind: Endpoint_Kind,
	id:   u64, // Event_Id or Entity_Id per kind.
}

event_endpoint :: proc "contextless" (id: Event_Id) -> Endpoint {
	return Endpoint{kind = .Event, id = u64(id)}
}

entity_endpoint :: proc "contextless" (id: Entity_Id) -> Endpoint {
	return Endpoint{kind = .Entity, id = u64(id)}
}

// CONFIDENCE_SCALE converts the stored fixed-point confidence to and from the
// documented 0..1 range. Confidence is stored as an integer so that identical
// inputs produce byte-identical derived chunks; float rounding would break the
// determinism requirement in docs/05.
CONFIDENCE_SCALE :: 10_000

// Confidence is a fixed-point value in [0, CONFIDENCE_SCALE].
Confidence :: distinct u16

// confidence_from_f32 clamps and quantizes a computed score.
confidence_from_f32 :: proc "contextless" (value: f32) -> Confidence {
	if value <= 0 {
		return Confidence(0)
	}
	if value >= 1 {
		return Confidence(CONFIDENCE_SCALE)
	}
	// Round half away from zero for a stable, implementation-independent result.
	return Confidence(u16(value * f32(CONFIDENCE_SCALE) + 0.5))
}

// confidence_to_f32 converts a stored confidence back to the documented range.
confidence_to_f32 :: proc "contextless" (value: Confidence) -> f32 {
	return f32(value) / f32(CONFIDENCE_SCALE)
}

// Edge connects two endpoints with a stated evidence level.
//
// `rule` and `reason` are meaningful only for Inferred edges: docs/03 requires
// an inferred edge to carry a rule identifier and a human-readable reason
// assembled from deterministic fields. Explicit and reconstructed edges leave
// them empty because their justification is their origin.
Edge :: struct {
	kind:       Edge_Kind,
	origin:     Edge_Origin,
	from:       Endpoint,
	to:         Endpoint,
	confidence: Confidence, // CONFIDENCE_SCALE for non-inferred edges.
	rule:       String_Id,  // Versioned rule identifier, e.g. "diag_names_path@1".
	reason:     String_Id,  // Deterministically assembled explanation.
}

// is_evidence reports whether an edge states a recorded or mechanically
// derived fact rather than a hypothesis. The UI uses careful language for
// everything else.
is_evidence :: proc "contextless" (edge: Edge) -> bool {
	return edge.origin != .Inferred
}
