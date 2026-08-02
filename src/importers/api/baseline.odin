package importer_api

import "core:strings"

import "src:trace/codec"
import "src:trace/model"

// Baseline capture.
//
// docs/06: "the strongest baseline is content read from a recorded starting
// commit and verified against recorded hashes. A working-tree snapshot is
// acceptable but is labeled observational."
//
// Without a baseline, replay starts from nothing and a patch against a file the
// session only modified — never created — is a `missing_baseline` gap. That is
// the honest result, but it is also the common case: an agent editing an
// existing repository mostly modifies files that already existed.
//
// The manifest records only what was actually read. docs/06 is explicit that it
// "must not imply that unobserved paths were absent", which is why absence is
// an explicit entry rather than the default: a path missing from the manifest
// means nothing was observed, not that the file was not there.

// MAX_BASELINE_FILES bounds how many files one import reads.
//
// A session that touched ten thousand paths would otherwise copy the whole
// repository into the trace. docs/08 requires the metadata panel to report
// content bytes precisely because this is a privacy surface, and an unbounded
// capture is one a user did not consent to.
MAX_BASELINE_FILES :: 4096

// MAX_BASELINE_FILE_BYTES bounds a single captured file.
//
// Large enough for source files, small enough that a stray binary or a
// generated bundle does not dominate the trace.
MAX_BASELINE_FILE_BYTES :: 4 << 20

// Baseline_Capture accumulates the manifest during an import.
Baseline_Capture :: struct {
	entries: [dynamic]model.Baseline_Entry,
	kind:    codec.Baseline_Kind,
	// Paths already captured, so a session that reads one file forty times
	// reads the repository once.
	seen: map[string]bool,
	// Counts for the import report. docs/05 requires every import to say what
	// it did rather than leaving the user to infer it.
	captured: int,
	absent:   int,
	skipped:  int,
}

baseline_capture_init :: proc(
	capture: ^Baseline_Capture,
	kind: codec.Baseline_Kind,
	allocator := context.allocator,
) {
	capture.entries = make([dynamic]model.Baseline_Entry, 0, 64, allocator)
	capture.seen = make(map[string]bool, 64, allocator)
	capture.kind = kind
}

baseline_capture_destroy :: proc(capture: ^Baseline_Capture) {
	for path in capture.seen {
		delete(path)
	}
	delete(capture.seen)
	delete(capture.entries)
	capture^ = {}
}

// capture_baseline reads the starting content of every path a session touched.
//
// Called after the adapter has run, so the set of paths is known: reading the
// repository up front would mean guessing which files matter, and reading it
// lazily during replay would mean touching the filesystem long after import,
// which docs/08 forbids.
//
// A path that cannot be read is recorded as skipped rather than absent. Those
// are different claims, and conflating them would let replay assert a file did
// not exist when the truth is that git could not produce it.
capture_baseline :: proc(
	capture: ^Baseline_Capture,
	sink: ^Sink,
	repository: ^Repository,
	options: Options,
) {
	if repository == nil || repository.root == "" {
		return
	}

	// docs/06: content from a recorded commit is verified; a working tree is
	// observational. The distinction travels into the trace so the viewer can
	// label a reconstruction honestly.
	commit := repository.head
	use_commit := repository.is_git && is_hex_object_name(commit)
	if use_commit && !repository.dirty {
		capture.kind = .Commit_Verified
	} else if use_commit {
		// A dirty tree means the commit is not what the session started from
		// for every file. The commit is still the best available evidence, but
		// it cannot be called verified.
		capture.kind = .Working_Tree_Observational
	} else {
		capture.kind = .Working_Tree_Observational
	}

	for entity in sink.entities {
		if entity.kind != .Path {
			continue
		}
		if len(capture.entries) >= MAX_BASELINE_FILES {
			capture.skipped += 1
			continue
		}

		path, found := model.string_get(&sink.strings, entity.name)
		if !found || path == "" {
			continue
		}
		if capture.seen[path] {
			continue
		}
		capture.seen[strings.clone(path)] = true

		capture_one(capture, sink, repository, path, entity.id, use_commit, commit)
	}

	if capture.captured > 0 || capture.absent > 0 {
		sink.report.capabilities += {.Before_After_Content}
	}
}

@(private)
capture_one :: proc(
	capture: ^Baseline_Capture,
	sink: ^Sink,
	repository: ^Repository,
	path: string,
	path_entity: model.Entity_Id,
	use_commit: bool,
	commit: string,
) {
	// The path was normalized when the adapter interned it, but this is where
	// it becomes an argument to another program, so it is checked again. docs/08
	// puts the check at the boundary, not once upstream.
	if !is_safe_relative_path(path) {
		capture.skipped += 1
		return
	}

	content: []byte
	read := false

	if use_commit {
		content, read = read_blob_at_commit(repository.root, commit, path, context.temp_allocator)
	}
	if !read {
		content, read = read_working_tree_file(repository.root, path, context.temp_allocator)
	}

	if !read {
		// docs/06: absence must be observed, not assumed. Git reporting no such
		// file at the commit *is* an observation, so a path absent from both
		// the commit and the working tree is recorded as absent — which lets
		// replay treat a later create as legitimate rather than a gap.
		//
		// A path the boundary refused, or one present but unreadable, is not
		// absent. Recording nothing for those is the only honest option:
		// claiming absence would be a false observation, and claiming content
		// would be invented.
		switch working_tree_presence(repository.root, path) {
		case .Absent:
			append(
				&capture.entries,
				model.Baseline_Entry{path = path_entity, exists = false, encoding = .Utf8},
			)
			capture.absent += 1
		case .Present, .Unknown:
			capture.skipped += 1
		}
		return
	}
	defer delete(content, context.temp_allocator)

	if len(content) > MAX_BASELINE_FILE_BYTES {
		capture.skipped += 1
		sink.report.warnings[int(codec.Warning_Category.Content_Truncated)] += 1
		return
	}

	if !is_probably_text(content) {
		// A binary file is not stored: the trace should not carry a compiled
		// artifact, and a diff over one is meaningless.
		//
		// No entry is recorded either. `exists = false` would be a false
		// observation — the file is plainly there — and the schema has no way
		// to say "present, content deliberately not captured". Recording
		// nothing means replay reports a gap for it, which is the honest
		// outcome for content Norn chose not to keep.
		capture.skipped += 1
		return
	}
	encoding := model.Text_Encoding.Utf8

	// Through the sink, so redaction runs before the content reaches the
	// writer. A repository file can hold a credential like any other source,
	// and docs/08 puts redaction ahead of the writer without exception.
	text := string(content)
	blob := add_blob_text(sink, text, encoding)
	if blob == model.NO_BLOB {
		capture.skipped += 1
		return
	}

	append(
		&capture.entries,
		model.Baseline_Entry {
			path = path_entity,
			content = blob,
			exists = true,
			encoding = encoding,
			// The digest of what was stored, not of what was read: redaction
			// may have changed the bytes, and replay verifies against the
			// stored form.
			digest = content_digest(sink, text),
		},
	)
	capture.captured += 1
}

// BINARY_SNIFF_BYTES is how much of a file is examined to classify it.
//
// A NUL byte in the first few kilobytes is the standard heuristic and is what
// git itself uses. Reading further costs more than it decides.
BINARY_SNIFF_BYTES :: 8000

@(private)
is_probably_text :: proc(content: []byte) -> bool {
	limit := min(len(content), BINARY_SNIFF_BYTES)
	for index in 0 ..< limit {
		if content[index] == 0 {
			return false
		}
	}
	return true
}
