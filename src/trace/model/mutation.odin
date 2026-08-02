package model

// File mutations and their replay status.
//
// docs/03-trace-model.md defines the mutation record; docs/06 defines how
// replay consumes it. The central rule is that Norn must be able to say "I do
// not know what this file contained" — Replay_Status exists so a gap is a
// representable state rather than a silently plausible guess.

// Mutation_Op is the operation a mutation performs.
Mutation_Op :: enum u8 {
	Unknown = 0,
	Create  = 1,
	Modify  = 2,
	Delete  = 3,
	Rename  = 4,
}

// mutation_op_for_kind maps a mutation event kind to its operation.
mutation_op_for_kind :: proc "contextless" (kind: Event_Kind) -> Mutation_Op {
	#partial switch kind {
	case .File_Create: return .Create
	case .File_Modify: return .Modify
	case .File_Delete: return .Delete
	case .File_Rename: return .Rename
	}
	return .Unknown
}

// Text_Encoding is the recorded encoding of file content. docs/03: Norn may
// display binary metadata but version one does not reconstruct binary diffs.
Text_Encoding :: enum u8 {
	Unknown  = 0,
	Utf8     = 1,
	Utf16_Le = 2,
	Utf16_Be = 3,
	Binary   = 4,
}

// is_text reports whether content in this encoding can be diffed and patched.
is_text :: proc "contextless" (encoding: Text_Encoding) -> bool {
	#partial switch encoding {
	case .Utf8, .Utf16_Le, .Utf16_Be:
		return true
	}
	return false
}

// Replay_Status records how much confidence replay can place in the file state
// produced by this mutation. docs/03 fixes this exact set.
Replay_Status :: enum u8 {
	// Content was reconstructed and its computed hash matched the recorded
	// hash. This is the only status that permits an unqualified display.
	Verified = 0,
	// Content was reconstructed but no recorded hash confirmed it.
	Reconstructed_Unverified = 1,
	// The baseline content needed to apply this mutation was not available.
	Missing_Baseline = 2,
	// A patch could not be applied strictly. docs/05: a failed hunk produces a
	// replay gap and a warning; version one never fuzzy-patches.
	Unsupported_Patch = 3,
	// Computed content did not match the recorded hash. The recorded hash is
	// believed over the reconstruction, and the result is a gap.
	Hash_Mismatch = 4,
	// Binary or unsupported content; metadata only.
	Binary_Opaque = 5,
}

// replay_status_name returns a stable identifier for reports and tests.
replay_status_name :: proc "contextless" (status: Replay_Status) -> string {
	switch status {
	case .Verified:                 return "verified"
	case .Reconstructed_Unverified: return "reconstructed_unverified"
	case .Missing_Baseline:         return "missing_baseline"
	case .Unsupported_Patch:        return "unsupported_patch"
	case .Hash_Mismatch:            return "hash_mismatch"
	case .Binary_Opaque:            return "binary_opaque"
	}
	return "unknown"
}

// is_replay_gap reports whether this status leaves content unknown at and
// after the mutation, until a later full-content event re-establishes it.
is_replay_gap :: proc "contextless" (status: Replay_Status) -> bool {
	#partial switch status {
	case .Missing_Baseline, .Unsupported_Patch, .Hash_Mismatch:
		return true
	}
	return false
}

// Mutation_Flag marks properties of the recorded evidence.
Mutation_Flag :: enum u8 {
	Has_Before_Hash = 0,
	Has_After_Hash  = 1,
	Has_Patch       = 2,
	Has_Content     = 3, // Full after-content is available as a blob.
}

Mutation_Flags :: bit_set[Mutation_Flag; u8]

// Mutation describes one recorded change to one path.
//
// `old_path` is meaningful only for Rename, where it names the path the
// content moved from. Rename preserves content identity, which is why the
// virtual repository models path identity and content identity separately.
Mutation :: struct {
	event_id:     Event_Id,
	path:         Entity_Id,
	old_path:     Entity_Id, // NO_ENTITY unless op is Rename.
	op:           Mutation_Op,
	encoding:     Text_Encoding,
	flags:        Mutation_Flags,
	status:       Replay_Status,
	before_hash:  Blob_Digest,
	after_hash:   Blob_Digest,
	patch_blob:   Blob_Id, // NO_BLOB when no patch was recorded.
	content_blob: Blob_Id, // NO_BLOB when no full content was recorded.
}

// Outcome_Status is the result of a command, test, build, or lint.
// docs/03 fixes this set.
Outcome_Status :: enum u8 {
	Unknown   = 0,
	Running   = 1,
	Passed    = 2,
	Failed    = 3,
	Skipped   = 4,
	Cancelled = 5,
	Errored   = 6,
}

// outcome_status_name returns a stable identifier for reports and tests.
outcome_status_name :: proc "contextless" (status: Outcome_Status) -> string {
	switch status {
	case .Unknown:   return "unknown"
	case .Running:   return "running"
	case .Passed:    return "passed"
	case .Failed:    return "failed"
	case .Skipped:   return "skipped"
	case .Cancelled: return "cancelled"
	case .Errored:   return "errored"
	}
	return "unknown"
}

// is_failure reports whether an outcome status is one a user would investigate.
is_failure :: proc "contextless" (status: Outcome_Status) -> bool {
	#partial switch status {
	case .Failed, .Errored:
		return true
	}
	return false
}

// Severity classifies a diagnostic. docs/03: diagnostics have severity and
// optional path, line, column, symbol, and code.
Severity :: enum u8 {
	Unknown = 0,
	Note    = 1,
	Info    = 2,
	Warning = 3,
	Error   = 4,
	Fatal   = 5,
}

// Baseline_Entry records one path observed before the session began.
//
// docs/06: "the baseline manifest records every path whose absence or content
// was actually verified. It must not imply that unobserved paths were absent."
// Absence is therefore an explicit entry with `exists` false, not the default —
// a path missing from the manifest means nothing was observed about it, which
// is a different claim from the file not being there.
//
// Defined here rather than in the replay package so the codec and the engine
// share one definition. Two structs that had to agree byte for byte would
// eventually disagree.
Baseline_Entry :: struct {
	path:     Entity_Id,
	content:  Blob_Id,
	exists:   bool,
	encoding: Text_Encoding,
	// Digest of the observed content, so replay can verify a reconstruction
	// against what was actually read rather than trusting the blob table.
	digest: Blob_Digest,
}
