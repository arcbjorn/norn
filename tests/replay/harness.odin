package test_replay

import "src:replay"
import "src:trace/model"

// Shared scaffolding for replay tests.
//
// Tests build mutation sequences directly against the canonical model rather
// than going through a trace file. Replay's correctness does not depend on the
// container, and driving it directly keeps a failure pointing at the engine
// instead of at the codec.

// Session accumulates content, mutations, and their sequences.
Session :: struct {
	content:   model.Blob_Table,
	mutations: [dynamic]model.Mutation,
	sequences: [dynamic]model.Sequence,
	baseline:  replay.Baseline,
	next_event: model.Event_Id,
	next_sequence: model.Sequence,
}

session_init :: proc(session: ^Session, kind := replay.Baseline_Kind.Commit_Verified) {
	model.blob_table_init(&session.content)
	session.mutations = make([dynamic]model.Mutation, 0, 16)
	session.sequences = make([dynamic]model.Sequence, 0, 16)
	replay.baseline_init(&session.baseline, kind)
	session.next_event = 1
	session.next_sequence = 1
}

session_destroy :: proc(session: ^Session) {
	model.blob_table_destroy(&session.content)
	delete(session.mutations)
	delete(session.sequences)
	replay.baseline_destroy(&session.baseline)
}

// session_source exposes the session's recorded content to the engine.
session_source :: proc(session: ^Session) -> replay.Content_Source {
	return replay.Content_Source {
		user_data = session,
		fetch = proc(user_data: rawptr, id: model.Blob_Id) -> ([]byte, bool) {
			session := cast(^Session)user_data
			return model.blob_content(&session.content, id)
		},
	}
}

// add_content interns bytes the trace is meant to have recorded.
add_content :: proc(session: ^Session, text: string) -> model.Blob_Id {
	id, _ := model.blob_add(&session.content, transmute([]byte)text)
	return id
}

// baseline_file declares a path that existed with known content at start.
//
// The digest is recorded because the importer records one: docs/06 reserves
// the verified label for content checked against a recorded hash, and a
// harness that omitted it would exercise only the weaker path.
baseline_file :: proc(session: ^Session, path: model.Entity_Id, text: string) {
	append(
		&session.baseline.entries,
		replay.Baseline_Entry {
			path = path,
			content = add_content(session, text),
			exists = true,
			encoding = .Utf8,
			digest = model.digest_content(transmute([]byte)text),
		},
	)
}

// baseline_file_with_digest declares a path whose recorded digest is supplied
// separately, so a test can make the manifest and the content disagree.
baseline_file_with_digest :: proc(
	session: ^Session,
	path: model.Entity_Id,
	text: string,
	digest: model.Blob_Digest,
) {
	append(
		&session.baseline.entries,
		replay.Baseline_Entry {
			path = path,
			content = add_content(session, text),
			exists = true,
			encoding = .Utf8,
			digest = digest,
		},
	)
}

// baseline_absent declares a path verified to be absent at start. docs/06
// requires absence to be an explicit observation rather than a default.
baseline_absent :: proc(session: ^Session, path: model.Entity_Id) {
	append(
		&session.baseline.entries,
		replay.Baseline_Entry{path = path, exists = false, encoding = .Utf8},
	)
}

@(private)
push :: proc(session: ^Session, mutation: model.Mutation) -> model.Event_Id {
	m := mutation
	m.event_id = session.next_event
	append(&session.mutations, m)
	append(&session.sequences, session.next_sequence)
	session.next_event += 1
	session.next_sequence += 1
	return m.event_id
}

// write_full records a mutation carrying explicit full content, with hashes.
// This is docs/05's strongest evidence level.
write_full :: proc(
	session: ^Session,
	path: model.Entity_Id,
	before: string,
	after: string,
	op := model.Mutation_Op.Modify,
) -> model.Event_Id {
	mutation := model.Mutation {
		path = path,
		op = op,
		encoding = .Utf8,
		content_blob = add_content(session, after),
		after_hash = model.digest_content(transmute([]byte)after),
		flags = {.Has_Content, .Has_After_Hash},
	}
	if op != .Create {
		mutation.before_hash = model.digest_content(transmute([]byte)before)
		mutation.flags += {.Has_Before_Hash}
	}
	return push(session, mutation)
}

// write_patch records a mutation carrying a unified diff and result hash.
write_patch :: proc(
	session: ^Session,
	path: model.Entity_Id,
	patch_text: string,
	expected_after: string,
	op := model.Mutation_Op.Modify,
) -> model.Event_Id {
	mutation := model.Mutation {
		path = path,
		op = op,
		encoding = .Utf8,
		patch_blob = add_content(session, patch_text),
		flags = {.Has_Patch},
	}
	if expected_after != "" {
		mutation.after_hash = model.digest_content(transmute([]byte)expected_after)
		mutation.flags += {.Has_After_Hash}
	}
	return push(session, mutation)
}

// write_patch_unverified records a patch with no result hash, so a successful
// application yields reconstructed-but-unverified content.
write_patch_unverified :: proc(
	session: ^Session,
	path: model.Entity_Id,
	patch_text: string,
	op := model.Mutation_Op.Modify,
) -> model.Event_Id {
	return push(
		session,
		model.Mutation {
			path = path,
			op = op,
			encoding = .Utf8,
			patch_blob = add_content(session, patch_text),
			flags = {.Has_Patch},
		},
	)
}

// delete_file records a deletion.
delete_file :: proc(session: ^Session, path: model.Entity_Id) -> model.Event_Id {
	return push(
		session,
		model.Mutation{path = path, op = .Delete, encoding = .Utf8},
	)
}

// rename_file records a rename from one path entity to another.
rename_file :: proc(
	session: ^Session,
	from: model.Entity_Id,
	to: model.Entity_Id,
) -> model.Event_Id {
	return push(
		session,
		model.Mutation{path = to, old_path = from, op = .Rename, encoding = .Utf8},
	)
}

// declare_only records a mutation with no content and no patch: docs/05's
// evidence level four, a provider-declared change that cannot be replayed.
declare_only :: proc(session: ^Session, path: model.Entity_Id) -> model.Event_Id {
	return push(
		session,
		model.Mutation{path = path, op = .Modify, encoding = .Utf8},
	)
}

// start builds an engine and timeline over the session and applies the
// baseline. The caller destroys both.
start :: proc(
	session: ^Session,
	engine: ^replay.Engine,
	timeline: ^replay.Timeline,
) {
	replay.engine_init(engine, session_source(session))
	replay.timeline_init(
		timeline,
		session.mutations[:],
		session.sequences[:],
		&session.baseline,
	)
	replay.engine_reset(engine, &session.baseline)
}

// run_all applies every mutation in order.
run_all :: proc(session: ^Session, engine: ^replay.Engine) {
	for mutation in session.mutations {
		replay.apply_mutation(engine, mutation)
	}
	engine.applied = len(session.mutations)
	if len(session.sequences) > 0 {
		engine.position = session.sequences[len(session.sequences) - 1]
	}
}
