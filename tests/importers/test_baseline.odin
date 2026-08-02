package test_importers

import "core:os"
import "core:strings"
import "core:testing"

import "src:core"
import api "src:importers/api"
import "src:trace/codec"
import "src:trace/model"

// Baseline capture.
//
// docs/06: "the baseline manifest records every path whose absence or content
// was actually verified. It must not imply that unobserved paths were absent."
//
// That sentence is the whole design. Three outcomes have to stay distinct —
// content was read, absence was observed, nothing was observed — because replay
// treats them differently and a viewer states them differently to the user.
// Collapsing the third into the second is the easy mistake, and it makes Norn
// assert a file did not exist when the truth is it was never looked at.

@(private)
Repo :: struct {
	root: string,
}

// make_repo builds a throwaway directory tree to capture from.
@(private)
make_repo :: proc(t: ^testing.T, name: string) -> Repo {
	directory, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no temporary directory available")
	}
	root := strings.concatenate({directory, "/norn-baseline-", name}, context.allocator)

	// Removed first, so a previous run cannot make this one pass.
	os.remove_all(root)
	if make_err := os.make_directory(root); make_err != nil {
		testing.fail_now(t, "could not create the test repository")
	}
	return Repo{root = root}
}

@(private)
destroy_repo :: proc(repo: ^Repo) {
	os.remove_all(repo.root)
	delete(repo.root)
}

@(private)
write_file :: proc(t: ^testing.T, repo: ^Repo, path: string, content: string) {
	full := strings.concatenate({repo.root, "/", path}, context.temp_allocator)

	// Create any parent directory the path names.
	last := -1
	for index in 0 ..< len(full) {
		if full[index] == '/' {
			last = index
		}
	}
	if last > len(repo.root) {
		os.make_directory_all(full[:last])
	}

	if err := os.write_entire_file(full, transmute([]byte)content); err != nil {
		testing.fail_now(t, "could not write a test file")
	}
}

// capture runs baseline capture over the paths a sink already knows.
@(private)
capture_for :: proc(
	t: ^testing.T,
	repo: ^Repo,
	paths: []string,
) -> (
	sink: ^api.Sink,
	capture: ^api.Baseline_Capture,
	repository: ^api.Repository,
) {
	// Heap-allocated so the caller can inspect them after this returns.
	sink = new(api.Sink)
	capture = new(api.Baseline_Capture)
	repository = new(api.Repository)
	redactor := new(api.Redactor)

	api.redactor_init(redactor)
	api.sink_init(sink, redactor, "test", "1.0.0", "session.jsonl")
	sink.redactor = redactor

	for path in paths {
		api.add_entity(sink, .Path, path, "")
	}

	inspected, err := api.inspect_repository(repo.root)
	testing.expect(t, core.ok(err), "the test repository must be inspectable")
	repository^ = inspected

	api.baseline_capture_init(capture, .None)
	api.capture_baseline(capture, sink, repository, api.Options{})
	return sink, capture, repository
}

@(private)
release :: proc(sink: ^api.Sink, capture: ^api.Baseline_Capture, repository: ^api.Repository) {
	redactor := sink.redactor
	api.baseline_capture_destroy(capture)
	api.sink_destroy(sink)
	api.repository_destroy(repository)
	if redactor != nil {
		api.redactor_destroy(redactor)
		free(redactor)
	}
	free(sink)
	free(capture)
	free(repository)
}

@(private)
entry_for :: proc(
	sink: ^api.Sink,
	capture: ^api.Baseline_Capture,
	path: string,
) -> (
	entry: model.Baseline_Entry,
	found: bool,
) {
	for candidate in capture.entries {
		for entity in sink.entities {
			if entity.id != candidate.path {
				continue
			}
			name, _ := model.string_get(&sink.strings, entity.name)
			if name == path {
				return candidate, true
			}
		}
	}
	return {}, false
}

@(test)
existing_content_is_captured :: proc(t: ^testing.T) {
	repo := make_repo(t, "content")
	defer destroy_repo(&repo)
	write_file(t, &repo, "a.odin", "package a\n")

	sink, capture, repository := capture_for(t, &repo, {"a.odin"})
	defer release(sink, capture, repository)

	testing.expect_value(t, capture.captured, 1)
	testing.expect_value(t, capture.absent, 0)

	entry, found := entry_for(sink, capture, "a.odin")
	testing.expect(t, found, "the path must appear in the manifest")
	testing.expect(t, entry.exists)
	testing.expect(t, entry.content != model.NO_BLOB, "present content must be stored")
	testing.expect(t, !model.digest_is_zero(entry.digest), "a digest must be recorded")
}

@(test)
an_absent_path_is_recorded_as_observed_absent :: proc(t: ^testing.T) {
	// docs/06: absence must be observed rather than assumed. Recording it lets
	// replay treat a later create as legitimate instead of a gap.
	repo := make_repo(t, "absent")
	defer destroy_repo(&repo)

	sink, capture, repository := capture_for(t, &repo, {"never-existed.odin"})
	defer release(sink, capture, repository)

	testing.expect_value(t, capture.absent, 1)
	testing.expect_value(t, capture.captured, 0)

	entry, found := entry_for(sink, capture, "never-existed.odin")
	testing.expect(t, found, "observed absence is an entry, not a gap in the manifest")
	testing.expect(t, !entry.exists)
	testing.expect_value(t, entry.content, model.NO_BLOB)
}

@(test)
an_escaping_path_is_not_recorded_as_absent :: proc(t: ^testing.T) {
	// The distinction docs/06 insists on. A path refused at the repository
	// boundary was never looked at, so claiming it was absent would be a false
	// observation — and would let replay assert a file did not exist.
	repo := make_repo(t, "escape")
	defer destroy_repo(&repo)
	write_file(t, &repo, "real.odin", "package real\n")

	sink, capture, repository := capture_for(
		t,
		&repo,
		{"../../../etc/passwd", "/etc/passwd", "real.odin"},
	)
	defer release(sink, capture, repository)

	// Only the in-bounds path was captured; neither escape produced an entry.
	testing.expect_value(t, capture.captured, 1)
	testing.expect_value(t, capture.absent, 0)
	testing.expect(t, capture.skipped >= 2, "each refused path must be counted")

	_, escaped := entry_for(sink, capture, "../../../etc/passwd")
	testing.expect(t, !escaped, "an escaping path must produce no entry at all")
}

@(test)
a_symlink_leaving_the_repository_is_not_recorded_as_absent :: proc(t: ^testing.T) {
	// The case the escaping-path test does not reach. A path like
	// "escape.odin" passes every string check — it is relative, normalized,
	// and inside the repository by name — and only resolving it reveals that
	// it points elsewhere.
	//
	// docs/08 requires the boundary check on the resolved target for exactly
	// this reason. Recording the refusal as absence would then be a false
	// observation about a file that plainly exists.
	repo := make_repo(t, "symlink")
	defer destroy_repo(&repo)

	outside_dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no temporary directory available")
	}
	outside := strings.concatenate(
		{outside_dir, "/norn-baseline-outside.txt"},
		context.temp_allocator,
	)
	if write_err := os.write_entire_file(outside, transmute([]byte)string("SECRET\n"));
	   write_err != nil {
		testing.fail_now(t, "could not write the outside file")
	}
	defer os.remove(outside)

	link := strings.concatenate({repo.root, "/escape.odin"}, context.temp_allocator)
	if link_err := os.symlink(outside, link); link_err != nil {
		// Not every filesystem permits symlinks; skipping beats a false pass.
		return
	}

	sink, capture, repository := capture_for(t, &repo, {"escape.odin"})
	defer release(sink, capture, repository)

	// Nothing was read, and nothing was claimed.
	testing.expect_value(t, capture.captured, 0)
	testing.expectf(
		t,
		capture.absent == 0,
		"a refused symlink must not be recorded as absent (absent=%d)",
		capture.absent,
	)
	testing.expect_value(t, capture.skipped, 1)

	_, found := entry_for(sink, capture, "escape.odin")
	testing.expect(t, !found, "a refused path must produce no manifest entry")

	// And the content beyond the boundary never entered the trace. Blob
	// identifiers index the entry slice, and index zero is the reserved
	// nothing-blob.
	for index in 1 ..< len(sink.blobs.entries) {
		content, got := model.blob_content(&sink.blobs, model.Blob_Id(index))
		if got {
			testing.expect(
				t,
				!strings.contains(string(content), "SECRET"),
				"content from outside the repository must never be stored",
			)
		}
	}
}

@(test)
a_binary_file_is_skipped_rather_than_called_absent :: proc(t: ^testing.T) {
	// Not stored, because a trace should not carry a compiled artifact. Also
	// not recorded as absent, because the file is plainly there — the schema
	// cannot say "present but deliberately not captured", so it says nothing.
	repo := make_repo(t, "binary")
	defer destroy_repo(&repo)
	write_file(t, &repo, "blob.bin", "\x00\x01\x02\x00binary\x00content")

	sink, capture, repository := capture_for(t, &repo, {"blob.bin"})
	defer release(sink, capture, repository)

	testing.expect_value(t, capture.captured, 0)
	testing.expect_value(t, capture.absent, 0)
	testing.expect_value(t, capture.skipped, 1)

	_, found := entry_for(sink, capture, "blob.bin")
	testing.expect(t, !found, "a binary file must not claim absence")
}

@(test)
capture_reads_each_path_once :: proc(t: ^testing.T) {
	// A session that reads one file forty times must read the repository once.
	repo := make_repo(t, "dedupe")
	defer destroy_repo(&repo)
	write_file(t, &repo, "a.odin", "package a\n")

	sink := new(api.Sink)
	capture := new(api.Baseline_Capture)
	repository := new(api.Repository)
	redactor := new(api.Redactor)
	api.redactor_init(redactor)
	api.sink_init(sink, redactor, "test", "1.0.0", "session.jsonl")
	sink.redactor = redactor
	defer release(sink, capture, repository)

	// add_entity deduplicates, so this is one entity named forty times.
	for _ in 0 ..< 40 {
		api.add_entity(sink, .Path, "a.odin", "")
	}

	inspected, err := api.inspect_repository(repo.root)
	testing.expect(t, core.ok(err))
	repository^ = inspected

	api.baseline_capture_init(capture, .None)
	api.capture_baseline(capture, sink, repository, api.Options{})

	testing.expect_value(t, len(capture.entries), 1)
	testing.expect_value(t, capture.captured, 1)
}

@(test)
captured_content_is_redacted_before_storage :: proc(t: ^testing.T) {
	// docs/08 puts redaction ahead of the writer without exception. A
	// repository file holds a credential as readily as a prompt does, and this
	// is content Norn copies into an artifact the user may share.
	repo := make_repo(t, "secret")
	defer destroy_repo(&repo)
	write_file(t, &repo, "config.odin", "key := \"sk-NOTAREALTOKENEXAMPLEONLYFAKE1234\"\n")

	sink, capture, repository := capture_for(t, &repo, {"config.odin"})
	defer release(sink, capture, repository)

	testing.expect_value(t, capture.captured, 1)

	entry, found := entry_for(sink, capture, "config.odin")
	testing.expect(t, found)

	content, got := model.blob_content(&sink.blobs, entry.content)
	testing.expect(t, got, "the captured blob must be readable")
	testing.expect(
		t,
		!strings.contains(string(content), "sk-NOTAREALTOKENEXAMPLEONLYFAKE1234"),
		"a credential in a repository file must be redacted like any other",
	)

	// The digest must describe the stored bytes, or replay reports a mismatch
	// on content that reconstructed correctly.
	testing.expect(
		t,
		model.digest_equal(entry.digest, model.digest_content(content)),
		"the digest must cover the redacted bytes",
	)
}

@(test)
the_manifest_survives_a_write_and_read :: proc(t: ^testing.T) {
	// The chunk is required rather than optional: a reader that skipped it
	// would replay from nothing and report gaps for files it could have
	// reconstructed.
	repo := make_repo(t, "roundtrip")
	defer destroy_repo(&repo)
	write_file(t, &repo, "a.odin", "package a\n")
	write_file(t, &repo, "b.odin", "package b\n")

	sink, capture, repository := capture_for(t, &repo, {"a.odin", "b.odin", "gone.odin"})
	defer release(sink, capture, repository)

	metadata := codec.Session_Metadata {
		baseline_kind = capture.kind,
	}
	content := api.finish(sink, model.Session_Id{}, metadata)
	content.baseline = capture.entries[:]

	writer: codec.Writer
	codec.writer_init(&writer, model.Session_Id{}, 1)
	defer codec.writer_destroy(&writer)

	testing.expect(t, core.ok(codec.writer_write_content(&writer, &content)))
	testing.expect(t, core.ok(codec.writer_finish(&writer)))

	trace, open_err := codec.open_trace(writer.buffer[:], core.DEFAULT_LIMITS, context.allocator)
	defer codec.trace_destroy(&trace)
	testing.expect(t, core.ok(open_err), "a trace with a baseline must open")

	testing.expect_value(t, len(trace.baseline), len(capture.entries))
	for entry, index in trace.baseline {
		original := capture.entries[index]
		testing.expect_value(t, entry.path, original.path)
		testing.expect_value(t, entry.exists, original.exists)
		testing.expect_value(t, entry.content, original.content)
		testing.expect(t, model.digest_equal(entry.digest, original.digest))
	}
}

@(test)
a_baseline_entry_cannot_claim_content_it_lacks :: proc(t: ^testing.T) {
	// Both directions are rejected at decode. An entry that says it exists but
	// names no content, or says it is absent while naming some, would make
	// replay reconstruct something the session never observed.
	inconsistent := []model.Baseline_Entry {
		{path = 1, exists = true, content = model.NO_BLOB},
		{path = 2, exists = false, content = model.Blob_Id(7)},
	}

	for entry in inconsistent {
		buffer := make([dynamic]u8, 0, 64, context.temp_allocator)
		codec.encode_baseline(&buffer, {entry})

		decoded := make([dynamic]model.Baseline_Entry, 0, 1, context.temp_allocator)
		err := codec.decode_baseline(buffer[:], &decoded)

		testing.expect(t, !core.ok(err), "an inconsistent entry must be refused")
		testing.expect_value(t, core.error_category(err), core.Category.Invariant_Violation)
	}
}

@(test)
a_truncated_manifest_is_refused :: proc(t: ^testing.T) {
	entries := []model.Baseline_Entry {
		{path = 1, exists = true, content = model.Blob_Id(1)},
		{path = 2, exists = true, content = model.Blob_Id(2)},
	}

	buffer := make([dynamic]u8, 0, 128, context.temp_allocator)
	codec.encode_baseline(&buffer, entries)

	// Every truncation point, because a reader that trusted the declared count
	// over the available bytes would read past the payload.
	for length in 0 ..< len(buffer) {
		decoded := make([dynamic]model.Baseline_Entry, 0, 2, context.temp_allocator)
		err := codec.decode_baseline(buffer[:length], &decoded)
		testing.expectf(t, !core.ok(err), "a manifest truncated to %d bytes must be refused", length)
	}
}
