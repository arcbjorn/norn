package test_app

import "core:strings"
import "core:testing"

import "src:app"
import "src:replay"
import "src:trace/codec"
import "src:trace/model"

// Replay driven from the playhead.
//
// docs/01: "dragging the playhead updates the virtual repository and all
// derived panels." The property that matters is that replay reflects the
// moment the playhead names — showing content from a different instant would
// be a false statement about the session, not a rendering glitch.

Replay_Fixture :: struct {
	trace:   codec.Trace,
	session: app.Replay_Session,
	path:    model.Entity_Id,
}

@(private)
replay_fixture_destroy :: proc(fixture: ^Replay_Fixture) {
	app.replay_session_destroy(&fixture.session)
	codec.trace_destroy(&fixture.trace)
}

// make_replay_fixture builds a session whose single file gains a line per
// second, so the content at any instant is predictable.
@(private)
make_replay_fixture :: proc(fixture: ^Replay_Fixture, steps := 5) -> bool {
	t := &fixture.trace
	model.string_table_init(&t.strings)
	model.blob_table_init(&t.blobs)
	model.payload_tables_init(&t.payloads)
	t.entities = make([dynamic]model.Entity, 0, 2)
	t.spans = make([dynamic]model.Span, 0, 1)
	t.events = make([dynamic]model.Event, 0, steps)
	t.edges = make([dynamic]model.Edge, 0, 1)
	t.mutations = make([dynamic]model.Mutation, 0, steps)
	t.directory = make([dynamic]codec.Directory_Entry, 0, 1)

	name, _ := model.string_intern(&t.strings, "src/parser.odin")
	append(&t.entities, model.Entity{id = 1, kind = .Path, name = name})
	fixture.path = 1

	// Each step rewrites the file with one more line, recorded as explicit
	// full content so replay can verify it.
	contents := []string {
		"one\n",
		"one\ntwo\n",
		"one\ntwo\nthree\n",
		"one\ntwo\nthree\nfour\n",
		"one\ntwo\nthree\nfour\nfive\n",
	}

	for index in 0 ..< min(steps, len(contents)) {
		text := contents[index]
		blob, _ := model.blob_add(&t.blobs, transmute([]byte)text)

		append(
			&t.events,
			model.Event {
				id = model.Event_Id(index + 1),
				sequence = model.Sequence(index + 1),
				kind = .File_Modify,
				flags = {.Has_Wall_Time},
				wall_time_ns = i64(index) * SECOND,
				primary_entity_id = 1,
			},
		)
		append(
			&t.mutations,
			model.Mutation {
				event_id = model.Event_Id(index + 1),
				path = 1,
				op = index == 0 ? .Create : .Modify,
				encoding = .Utf8,
				content_blob = blob,
				after_hash = model.digest_content(transmute([]byte)text),
				flags = {.Has_Content, .Has_After_Hash},
			},
		)
	}

	// Blob content must be resident for the engine's fetch to find it, which
	// is how a trace read from disk behaves too.
	return app.replay_session_init(&fixture.session, t)
}

@(test)
replay_reflects_the_playhead :: proc(t: ^testing.T) {
	// The central property: the content shown is the content at the selected
	// moment, not at some other one.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	Case :: struct {
		playhead_ns: i64,
		expected:    string,
	}
	cases := []Case {
		{0, "one\n"},
		{1 * SECOND, "one\ntwo\n"},
		{2 * SECOND, "one\ntwo\nthree\n"},
		{4 * SECOND, "one\ntwo\nthree\nfour\nfive\n"},
	}

	for c in cases {
		app.seek_to(&fixture.session, &fixture.trace, c.playhead_ns)
		resolved := app.resolve_path(&fixture.session, fixture.path)

		testing.expectf(
			t,
			replay.has_content(resolved),
			"no content at %d ns (status %v)",
			c.playhead_ns,
			resolved.status,
		)
		testing.expectf(
			t,
			string(resolved.content) == c.expected,
			"at %d ns got %q, expected %q",
			c.playhead_ns,
			string(resolved.content),
			c.expected,
		)
	}
}

@(test)
seeking_backwards_agrees_with_seeking_forwards :: proc(t: ^testing.T) {
	// Scrubbing a timeline goes both ways. A backward seek that produced a
	// different state than a forward one would make the panel's content
	// depend on how the user arrived, which is indefensible.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	// Copies, not borrows: resolve returns a view into the engine's content
	// store, and seeking again can reuse that memory.
	forward := make([dynamic]string, 0, 5)
	defer {
		for text in forward {
			delete(text)
		}
		delete(forward)
	}

	for step in 0 ..< 5 {
		app.seek_to(&fixture.session, &fixture.trace, i64(step) * SECOND)
		resolved := app.resolve_path(&fixture.session, fixture.path)
		append(&forward, strings.clone(string(resolved.content)))
	}

	for step := 4; step >= 0; step -= 1 {
		app.seek_to(&fixture.session, &fixture.trace, i64(step) * SECOND)
		resolved := app.resolve_path(&fixture.session, fixture.path)
		testing.expectf(
			t,
			string(resolved.content) == forward[step],
			"backward seek to step %d gave %q, forward gave %q",
			step,
			string(resolved.content),
			forward[step],
		)
	}
}

@(test)
a_playhead_before_the_session_shows_the_baseline :: proc(t: ^testing.T) {
	// The fixture creates its file at the first event, so before that the
	// path did not exist. Reporting content there would invent history.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, -100 * SECOND)
	resolved := app.resolve_path(&fixture.session, fixture.path)

	testing.expect(
		t,
		!replay.has_content(resolved),
		"a moment before the file existed must not show content",
	)
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Unknown_Path)
}

@(test)
a_playhead_past_the_session_shows_the_final_state :: proc(t: ^testing.T) {
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, 1000 * SECOND)
	resolved := app.resolve_path(&fixture.session, fixture.path)

	testing.expect(t, replay.has_content(resolved))
	testing.expect_value(t, string(resolved.content), "one\ntwo\nthree\nfour\nfive\n")
}

@(test)
seeking_to_the_same_moment_twice_is_free :: proc(t: ^testing.T) {
	// The frame loop seeks every frame, so an unmoved playhead must not
	// re-walk the mutation chain.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	testing.expect(t, app.seek_to(&fixture.session, &fixture.trace, 2 * SECOND))
	testing.expect(
		t,
		!app.seek_to(&fixture.session, &fixture.trace, 2 * SECOND),
		"an unchanged playhead must report no movement",
	)
}

@(test)
a_trace_with_no_mutations_is_not_replayable :: proc(t: ^testing.T) {
	// A session that only ran commands has no file history. Saying so is
	// better than presenting an empty repository as a reconstructed one.
	fixture: Replay_Fixture
	trace := &fixture.trace
	model.string_table_init(&trace.strings)
	model.blob_table_init(&trace.blobs)
	model.payload_tables_init(&trace.payloads)
	trace.entities = make([dynamic]model.Entity, 0, 1)
	trace.spans = make([dynamic]model.Span, 0, 1)
	trace.events = make([dynamic]model.Event, 0, 1)
	trace.edges = make([dynamic]model.Edge, 0, 1)
	trace.mutations = make([dynamic]model.Mutation, 0, 1)
	trace.directory = make([dynamic]codec.Directory_Entry, 0, 1)
	defer replay_fixture_destroy(&fixture)

	append(
		&trace.events,
		model.Event{id = 1, sequence = 1, kind = .Command_Start, flags = {.Has_Wall_Time}},
	)

	testing.expect(
		t,
		!app.replay_session_init(&fixture.session, trace),
		"a trace with no mutations is not replayable",
	)

	// Every query must still answer safely rather than crashing.
	testing.expect(t, !app.seek_to(&fixture.session, trace, SECOND))
	resolved := app.resolve_path(&fixture.session, model.Entity_Id(1))
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Unknown_Path)
	testing.expect_value(t, app.replay_gap_count(&fixture.session), 0)
}

@(test)
an_unknown_path_reports_unknown :: proc(t: ^testing.T) {
	// docs/06 distinguishes a path that is absent from one nothing is known
	// about. Conflating them would claim knowledge the trace does not have.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, 2 * SECOND)
	resolved := app.resolve_path(&fixture.session, model.Entity_Id(99))
	testing.expect_value(t, resolved.status, replay.Resolved_Status.Unknown_Path)
}

@(test)
previous_content_is_the_state_before_the_last_change :: proc(t: ^testing.T) {
	// This is what "since previous change" compares against, so it must be
	// the state immediately before the most recent edit, not two edits back.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, 2 * SECOND)
	previous, available := app.previous_mutation_content(
		&fixture.session,
		&fixture.trace,
		fixture.path,
	)
	testing.expect(t, available)
	defer delete(previous)

	testing.expect_value(t, string(previous), "one\ntwo\n")

	// The shared engine must be back where it was, or every other panel would
	// read a different moment than the one the playhead names.
	current := app.resolve_path(&fixture.session, fixture.path)
	testing.expect_value(t, string(current.content), "one\ntwo\nthree\n")
}

@(test)
previous_content_is_unavailable_at_the_first_change :: proc(t: ^testing.T) {
	// Before the first edit there is no previous state to compare against,
	// and inventing one would be a claim about content nobody recorded.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, 0)
	_, available := app.previous_mutation_content(
		&fixture.session,
		&fixture.trace,
		fixture.path,
	)
	testing.expect(t, !available, "the first change has no prior state")
}

@(test)
replay_reports_gaps_rather_than_hiding_them :: proc(t: ^testing.T) {
	// A gap is a recorded fact about the session. The count is what lets the
	// interface say the reconstruction is partial.
	fixture: Replay_Fixture
	if !make_replay_fixture(&fixture) {
		testing.fail_now(t, "the fixture must be replayable")
	}
	defer replay_fixture_destroy(&fixture)

	app.seek_to(&fixture.session, &fixture.trace, 4 * SECOND)

	// Every mutation in this fixture carries full content, so nothing is a
	// gap. A non-zero count here would mean replay failed silently.
	testing.expect_value(t, app.replay_gap_count(&fixture.session), 0)
}
