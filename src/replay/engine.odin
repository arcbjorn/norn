package replay

import "src:core"
import "src:trace/model"

// Mutation application and seeking.
//
// docs/06 fixes the application order:
//   1. resolve the path state immediately before the mutation;
//   2. verify before_hash when present;
//   3. apply operation-specific behavior;
//   4. apply a patch strictly or load explicit after content;
//   5. compute the result hash;
//   6. verify after_hash when present;
//   7. publish the new immutable path state;
//   8. record any gap without corrupting later known states.
//
// Step 8 is the one that shapes the code: a mutation that cannot be replayed
// must leave every other path untouched and must not prevent this path from
// recovering later.

// Apply_Outcome reports what happened to one mutation, so the engine's caller
// can count gaps by reason rather than only observing the final state.
Apply_Outcome :: struct {
	event:  model.Event_Id,
	path:   model.Entity_Id,
	status: model.Replay_Status,
	// Set when a patch failed, to explain why.
	patch_error: Patch_Error,
}

// Engine holds the state a replay walk mutates.
//
// `store` owns reconstructed content. `source` resolves content recorded in
// the trace. Keeping them separate means recorded evidence is never confused
// with something replay computed.
Engine :: struct {
	state:    Repository_State,
	store:    Content_Store,
	source:   Content_Source,
	outcomes: [dynamic]Apply_Outcome,

	// Sequence of the last mutation applied, so a caller can tell how far the
	// state has advanced without tracking it separately.
	position: model.Sequence,
	// Number of mutations applied to reach the current state.
	//
	// Seeking needs this rather than deriving a count from `position`: after a
	// snapshot restore the state reflects a mutation index directly, and
	// recovering that index from a sequence would depend on the timeline the
	// engine does not hold.
	applied: int,
}

engine_init :: proc(
	engine: ^Engine,
	source: Content_Source,
	allocator := context.allocator,
) {
	state_init(&engine.state, allocator)
	store_init(&engine.store, allocator)
	engine.source = source
	engine.outcomes = make([dynamic]Apply_Outcome, 0, 64, allocator)
	engine.position = 0
	engine.applied = 0
}

engine_destroy :: proc(engine: ^Engine) {
	state_destroy(&engine.state)
	store_destroy(&engine.store)
	delete(engine.outcomes)
	engine^ = {}
}

// engine_reset returns the engine to the baseline without discarding the
// content it has already reconstructed.
//
// Keeping the store is what makes backward seeking affordable: seeking back
// re-applies mutations from a snapshot, and content interned on the way
// forward is found again by digest rather than recomputed.
engine_reset :: proc(engine: ^Engine, baseline: ^Baseline) {
	clear(&engine.state.paths)
	clear(&engine.outcomes)
	engine.position = 0
	engine.applied = 0
	baseline_apply(baseline, &engine.state)
}

// engine_content resolves a blob from either the trace or the reconstruction
// store. Reconstructed content is checked first because it is the more recent
// interpretation of a path when both exist.
@(private)
engine_content :: proc(engine: ^Engine, ref: Content_Ref) -> (content: []byte, ok: bool) {
	// Dispatch on origin rather than trying both tables. Recorded and
	// reconstructed identifiers both start at 1, so a fallback search would
	// happily return another file's bytes for a valid-looking identifier.
	switch ref.origin {
	case .None:
		return nil, false
	case .Reconstructed:
		return store_get(&engine.store, ref.id)
	case .Recorded:
		return content_fetch(engine.source, ref.id)
	}
	return nil, false
}

// apply_mutation performs the documented eight steps for one mutation.
//
// It never fails in the error-union sense: an unreplayable mutation is a
// recorded fact about the session, not a malfunction of the debugger. The
// result is a status, and the affected path is left in a state that says
// plainly what is known.
apply_mutation :: proc(engine: ^Engine, mutation: model.Mutation) -> Apply_Outcome {
	outcome := Apply_Outcome {
		event = mutation.event_id,
		path  = mutation.path,
	}

	// Step 1: resolve the state immediately before this mutation.
	previous, known := state_get(&engine.state, mutation.path)

	// Binary content is carried as metadata only; docs/03 excludes binary
	// reconstruction from version one.
	if mutation.encoding == .Binary {
		state_put(
			&engine.state,
			Path_State {
				path = mutation.path,
				content = recorded_content(mutation.content_blob),
				exists = mutation.op != .Delete,
				encoding = .Binary,
				verification = .Binary,
				last_mutation = mutation.event_id,
			},
		)
		outcome.status = .Binary_Opaque
		append(&engine.outcomes, outcome)
		return outcome
	}

	switch mutation.op {
	case .Rename:
		return apply_rename(engine, mutation, outcome)

	case .Delete:
		// docs/06: delete requires a known existing path when verification is
		// possible. When the path was never observed, the deletion is still
		// recorded, but nothing about the prior content can be claimed.
		state_put(
			&engine.state,
			Path_State {
				path = mutation.path,
				content = NO_CONTENT,
				exists = false,
				encoding = previous.encoding,
				verification = .Unknown,
				last_mutation = mutation.event_id,
			},
		)
		outcome.status = .Verified if known && previous.exists else .Reconstructed_Unverified
		append(&engine.outcomes, outcome)
		return outcome

	case .Create, .Modify, .Unknown:
		// Handled below.
	}

	// Step 2: verify before_hash against the state we are about to change.
	//
	// A mismatch means the trace and the reconstruction disagree about what
	// the file contained. The recorded hash is the evidence, so the
	// reconstruction is what gets doubted: the path becomes a gap.
	if .Has_Before_Hash in mutation.flags && !model.digest_is_zero(mutation.before_hash) {
		if known && previous.exists && has_ref(previous.content) {
			existing, got := engine_content(engine, previous.content)
			if got && !model.digest_equal(model.digest_content(existing), mutation.before_hash) {
				return record_gap(engine, mutation, outcome, .Hash_Mismatch, .None)
			}
		}
	}

	// Steps 3 and 4: obtain the resulting content.
	result: []byte
	produced := false

	if .Has_Content in mutation.flags && mutation.content_blob != model.NO_BLOB {
		// Explicit full content is the strongest evidence and needs no prior
		// state, which is why it can re-establish replay after a gap.
		content, got := engine_content(engine, recorded_content(mutation.content_blob))
		if !got {
			return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
		}
		result = content
		produced = true

	} else if .Has_Patch in mutation.flags && mutation.patch_blob != model.NO_BLOB {
		// A patch needs a known base. Without one there is nothing to apply
		// it to, and guessing the base is exactly what strictness forbids.
		if previous.verification == .Gap {
			return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
		}

		base: []byte
		if mutation.op == .Create {
			// A create patches an empty file.
			base = nil
		} else {
			if !known || !previous.exists || !has_ref(previous.content) {
				return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
			}
			content, got := engine_content(engine, previous.content)
			if !got {
				return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
			}
			base = content
		}

		patch_bytes, got := engine_content(engine, recorded_content(mutation.patch_blob))
		if !got {
			return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
		}

		patch, parse_reason := parse_patch(patch_bytes, context.temp_allocator)
		if parse_reason != .None {
			return record_gap(engine, mutation, outcome, .Unsupported_Patch, parse_reason)
		}
		defer patch_destroy(&patch)

		patched, apply_reason := apply_patch(base, &patch, context.temp_allocator)
		if apply_reason != .None {
			return record_gap(engine, mutation, outcome, .Unsupported_Patch, apply_reason)
		}
		result = patched
		produced = true

	} else {
		// docs/05 evidence level four: a provider-declared mutation without
		// enough content to replay. The change is real and recorded; its
		// result simply cannot be reconstructed.
		return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
	}

	if !produced {
		return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
	}

	// Steps 5 and 6: compute the result hash and verify it when recorded.
	digest := model.digest_content(result)
	verification := Verification.Unverified
	status := model.Replay_Status.Reconstructed_Unverified

	if .Has_After_Hash in mutation.flags && !model.digest_is_zero(mutation.after_hash) {
		if !model.digest_equal(digest, mutation.after_hash) {
			// The reconstruction produced bytes the trace says are wrong.
			// Publishing them would be worse than admitting the gap.
			return record_gap(engine, mutation, outcome, .Hash_Mismatch, .None)
		}
		verification = .Verified
		status = .Verified
	}

	// Step 7: publish the new state.
	content_id, stored := store_add(&engine.store, result, mutation.encoding)
	if !stored {
		return record_gap(engine, mutation, outcome, .Missing_Baseline, .None)
	}

	state_put(
		&engine.state,
		Path_State {
			path = mutation.path,
			content = reconstructed_content(content_id),
			exists = true,
			encoding = mutation.encoding,
			verification = verification,
			last_mutation = mutation.event_id,
		},
	)

	outcome.status = status
	append(&engine.outcomes, outcome)
	return outcome
}

// apply_rename moves content identity from one path to another.
//
// docs/06: rename preserves content identity and records both paths. The
// content blob is carried across unchanged rather than re-read, which is what
// makes a rename chain cheap and what keeps identical content at two paths
// pointing at one blob.
@(private)
apply_rename :: proc(
	engine: ^Engine,
	mutation: model.Mutation,
	outcome_in: Apply_Outcome,
) -> Apply_Outcome {
	outcome := outcome_in
	previous, known := state_get(&engine.state, mutation.old_path)

	// The source path becomes absent whether or not its content was known.
	state_put(
		&engine.state,
		Path_State {
			path = mutation.old_path,
			content = NO_CONTENT,
			exists = false,
			encoding = previous.encoding,
			verification = .Unknown,
			last_mutation = mutation.event_id,
		},
	)

	if !known || !previous.exists {
		// A rename from a path nothing is known about produces a destination
		// whose content is equally unknown. Recording it as a gap keeps the
		// destination honest rather than presenting it as empty.
		state_put(
			&engine.state,
			Path_State {
				path = mutation.path,
				content = NO_CONTENT,
				exists = true,
				encoding = mutation.encoding,
				verification = .Gap,
				last_mutation = mutation.event_id,
				gap_event = mutation.event_id,
			},
		)
		outcome.status = .Missing_Baseline
		append(&engine.outcomes, outcome)
		return outcome
	}

	state_put(
		&engine.state,
		Path_State {
			path = mutation.path,
			content = previous.content,
			exists = true,
			encoding = previous.encoding,
			verification = previous.verification,
			last_mutation = mutation.event_id,
		},
	)

	outcome.status = .Verified if previous.verification == .Verified else .Reconstructed_Unverified
	append(&engine.outcomes, outcome)
	return outcome
}

// record_gap marks a path unknown from this mutation forward.
//
// Only the affected path is touched. docs/06 step 8 requires a gap to be
// recorded without corrupting later known states, and confining the damage to
// one path is what makes a later full-content mutation able to recover it.
@(private)
record_gap :: proc(
	engine: ^Engine,
	mutation: model.Mutation,
	outcome_in: Apply_Outcome,
	status: model.Replay_Status,
	patch_error: Patch_Error,
) -> Apply_Outcome {
	outcome := outcome_in
	previous, _ := state_get(&engine.state, mutation.path)

	state_put(
		&engine.state,
		Path_State {
			path = mutation.path,
			content = NO_CONTENT,
			// A delete that could not be verified still removed the file; any
			// other failed operation leaves the path present with unknown
			// content.
			exists = mutation.op != .Delete,
			encoding = mutation.encoding if mutation.encoding != .Unknown else previous.encoding,
			verification = .Gap,
			last_mutation = mutation.event_id,
			gap_event = mutation.event_id,
		},
	)

	outcome.status = status
	outcome.patch_error = patch_error
	append(&engine.outcomes, outcome)
	return outcome
}

// resolve returns the current state of a path in the contract's terms.
resolve :: proc(engine: ^Engine, path: model.Entity_Id) -> Resolved_Content {
	state, known := state_get(&engine.state, path)
	if !known {
		// Nothing in the trace mentioned this path. That is not the same as
		// the path being absent, and docs/06 forbids conflating them.
		return Resolved_Content{status = .Unknown_Path}
	}

	result := Resolved_Content {
		encoding      = state.encoding,
		last_mutation = state.last_mutation,
		gap_event     = state.gap_event,
	}

	if state.verification == .Gap {
		result.status = .Gap
		return result
	}
	if !state.exists {
		// A path that was observed and then removed reports a deletion; one
		// that was only ever recorded as absent reports absence.
		result.status = .Deleted if state.last_mutation != model.NO_EVENT else .Absent
		return result
	}
	if state.verification == .Binary {
		result.status = .Binary
		return result
	}

	content, got := engine_content(engine, state.content)
	if !got {
		result.status = .Gap
		return result
	}
	result.content = content
	result.digest = model.digest_content(content)

	switch state.verification {
	case .Verified:      result.status = .Verified
	case .Observational: result.status = .Observational
	case .Unverified:    result.status = .Unverified
	case .Unknown:       result.status = .Unverified
	case .Gap:           result.status = .Gap
	case .Binary:        result.status = .Binary
	}
	return result
}

// gap_count reports how many applied mutations produced a replay gap.
gap_count :: proc(engine: ^Engine) -> int {
	total := 0
	for outcome in engine.outcomes {
		if model.is_replay_gap(outcome.status) {
			total += 1
		}
	}
	return total
}

// verified_count reports how many applied mutations were hash-verified.
verified_count :: proc(engine: ^Engine) -> int {
	total := 0
	for outcome in engine.outcomes {
		if outcome.status == .Verified {
			total += 1
		}
	}
	return total
}

// engine_error surfaces a replay failure in the shared error model, for
// callers such as `norn validate --mode replay` that report categories.
engine_error :: proc(engine: ^Engine) -> core.Error {
	if gap_count(engine) == 0 {
		return nil
	}
	return core.err_make(
		.Invariant_Violation,
		"trace contains mutations that could not be replayed",
		.Degraded,
	)
}
