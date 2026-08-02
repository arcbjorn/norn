package test_replay

import "core:testing"

import "src:replay"
import "src:trace/model"

// Replay engine behavior and the property tests required by docs/09.

PATH_A :: model.Entity_Id(1)
PATH_B :: model.Entity_Id(2)
PATH_C :: model.Entity_Id(3)

@(test)
full_content_mutation_is_verified :: proc(t: ^testing.T) {
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "one\n")
	write_full(&session, PATH_A, "one\n", "two\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(resolved.content), "two\n")
	testing.expect_value(t, replay.gap_count(&engine), 0)
}

@(test)
patch_mutation_reconstructs_content :: proc(t: ^testing.T) {
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "alpha\nbeta\ngamma\n")
	patch := `@@ -2,1 +2,1 @@
-beta
+BETA
`
	write_patch(&session, PATH_A, patch, "alpha\nBETA\ngamma\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(resolved.content), "alpha\nBETA\ngamma\n")
}

@(test)
patch_without_a_result_hash_is_unverified :: proc(t: ^testing.T) {
	// docs/06 distinguishes verified from reconstructed-but-unverified, and
	// the viewer must be able to tell them apart.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "x\n")
	write_patch_unverified(&session, PATH_A, "@@ -1,1 +1,1 @@\n-x\n+y\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Unverified)
	testing.expect_value(t, string(resolved.content), "y\n")
}

@(test)
reported_hashes_match_produced_bytes :: proc(t: ^testing.T) {
	// docs/09 property: reported hashes match produced bytes.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "a\n")
	write_full(&session, PATH_A, "a\n", "b\n")
	write_patch(&session, PATH_A, "@@ -1,1 +1,1 @@\n-b\n+c\n", "c\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect(t, replay.has_content(resolved))
	recomputed := model.digest_content(resolved.content)
	testing.expect(
		t,
		model.digest_equal(recomputed, resolved.digest),
		"the reported digest must be the digest of the returned bytes",
	)
}

@(test)
rename_preserves_content_identity :: proc(t: ^testing.T) {
	// docs/09 property: rename preserves content identity.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "moved content\n")
	rename_file(&session, PATH_A, PATH_B)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	source := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, source.status, replay.Resolved_Status.Deleted)

	destination := replay.resolve(&engine, PATH_B)
	testing.expect_value(t, destination.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(destination.content), "moved content\n")
}

@(test)
rename_chain_preserves_content :: proc(t: ^testing.T) {
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "chained\n")
	rename_file(&session, PATH_A, PATH_B)
	rename_file(&session, PATH_B, PATH_C)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	final := replay.resolve(&engine, PATH_C)
	testing.expect_value(t, final.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(final.content), "chained\n")
	testing.expect_value(t, replay.gap_count(&engine), 0)
}

@(test)
failed_patch_produces_a_gap_not_wrong_content :: proc(t: ^testing.T) {
	// The central safety property. A fuzzy patcher would find "beta" and apply
	// anyway; strict replay must report that it does not know.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "prelude\nalpha\nbeta\n")
	write_patch(&session, PATH_A, "@@ -1,1 +1,1 @@\n-beta\n+BETA\n", "")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Gap)
	testing.expect(t, !replay.has_content(resolved), "a gap must not offer content")
	testing.expect_value(t, replay.gap_count(&engine), 1)

	// docs/06: a gap names the event that introduced it.
	testing.expect(t, resolved.gap_event != model.NO_EVENT)
}

@(test)
hash_mismatch_produces_a_gap :: proc(t: ^testing.T) {
	// The patch applies cleanly but yields content the trace says is wrong.
	// The recorded hash is the evidence, so the reconstruction is doubted.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "x\n")
	push_mismatch(&session, PATH_A)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Gap)
	testing.expect_value(t, replay.gap_count(&engine), 1)
}

@(private)
push_mismatch :: proc(session: ^Session, path: model.Entity_Id) {
	// A patch whose declared result hash does not match what it produces.
	patch := "@@ -1,1 +1,1 @@\n-x\n+y\n"
	mutation := model.Mutation {
		path = path,
		op = .Modify,
		encoding = .Utf8,
		patch_blob = add_content(session, patch),
		after_hash = model.digest_content(transmute([]byte)string("SOMETHING ELSE\n")),
		flags = {.Has_Patch, .Has_After_Hash},
	}
	mutation.event_id = session.next_event
	append(&session.mutations, mutation)
	append(&session.sequences, session.next_sequence)
	session.next_event += 1
	session.next_sequence += 1
}

@(test)
full_content_recovers_from_a_prior_gap :: proc(t: ^testing.T) {
	// docs/09 property: a full-content event can recover from a replay gap.
	// docs/06 states the same rule, and it is what keeps one bad patch from
	// poisoning the rest of a session.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "start\n")
	write_patch(&session, PATH_A, "@@ -1,1 +1,1 @@\n-nomatch\n+broken\n", "")
	write_full(&session, PATH_A, "", "recovered\n", .Modify)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	// After the failed patch the path is a gap.
	replay.apply_mutation(&engine, session.mutations[0])
	mid := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, mid.status, replay.Resolved_Status.Gap)

	// Explicit full content needs no prior state, so it re-establishes replay.
	replay.apply_mutation(&engine, session.mutations[1])
	after := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, after.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(after.content), "recovered\n")
}

@(test)
a_gap_does_not_corrupt_other_paths :: proc(t: ^testing.T) {
	// docs/06 step 8: record a gap without corrupting later known states.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "a\n")
	baseline_file(&session, PATH_B, "b\n")
	write_patch(&session, PATH_A, "@@ -1,1 +1,1 @@\n-nomatch\n+x\n", "")
	write_full(&session, PATH_B, "b\n", "B\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	damaged := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, damaged.status, replay.Resolved_Status.Gap)

	intact := replay.resolve(&engine, PATH_B)
	testing.expect_value(t, intact.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(intact.content), "B\n")
}

@(test)
declared_mutation_without_content_is_a_gap :: proc(t: ^testing.T) {
	// docs/05 evidence level four: a provider-declared mutation without enough
	// content to replay. It is a real recorded change whose result is unknown.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "before\n")
	declare_only(&session, PATH_A)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Gap)
}

@(test)
unobserved_paths_report_unknown_not_absent :: proc(t: ^testing.T) {
	// docs/06: the baseline manifest must not imply that unobserved paths were
	// absent. Absence is a positive claim and requires evidence.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "known\n")
	baseline_absent(&session, PATH_B)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	verified_absent := replay.resolve(&engine, PATH_B)
	testing.expect_value(t, verified_absent.status, replay.Resolved_Status.Absent)

	never_mentioned := replay.resolve(&engine, PATH_C)
	testing.expect_value(t, never_mentioned.status, replay.Resolved_Status.Unknown_Path)
}

@(test)
observational_baseline_is_labeled :: proc(t: ^testing.T) {
	// docs/06: a working-tree snapshot is acceptable but labeled
	// observational, and that label must survive into what the viewer shows.
	session: Session
	session_init(&session, .Working_Tree_Observational)
	defer session_destroy(&session)

	baseline_file(&session, PATH_A, "observed\n")

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Observational)
	testing.expect_value(t, string(resolved.content), "observed\n")
}

@(test)
create_and_delete_round_trip :: proc(t: ^testing.T) {
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	baseline_absent(&session, PATH_A)
	write_full(&session, PATH_A, "", "created\n", .Create)
	delete_file(&session, PATH_A)

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	replay.apply_mutation(&engine, session.mutations[0])
	created := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, created.status, replay.Resolved_Status.Verified)
	testing.expect_value(t, string(created.content), "created\n")

	replay.apply_mutation(&engine, session.mutations[1])
	deleted := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, deleted.status, replay.Resolved_Status.Deleted)
	testing.expect(t, !replay.has_content(deleted))
}

@(test)
binary_content_is_opaque_not_reconstructed :: proc(t: ^testing.T) {
	// docs/03: Norn may display binary metadata but version one does not
	// reconstruct binary diffs.
	session: Session
	session_init(&session)
	defer session_destroy(&session)

	mutation := model.Mutation {
		path = PATH_A,
		op = .Modify,
		encoding = .Binary,
		event_id = 1,
	}
	append(&session.mutations, mutation)
	append(&session.sequences, model.Sequence(1))

	engine: replay.Engine
	timeline: replay.Timeline
	start(&session, &engine, &timeline)
	defer replay.engine_destroy(&engine)
	defer replay.timeline_destroy(&timeline)

	run_all(&session, &engine)

	resolved := replay.resolve(&engine, PATH_A)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Binary)
	testing.expect(t, !replay.has_content(resolved), "binary content is metadata only")
}
