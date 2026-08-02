package test_importers

import "core:os"
import "core:strings"
import "core:testing"

import "src:core"
import api "src:importers/api"

// Repository identity and the git boundary.
//
// docs/08: opening or replaying a trace must never execute a command, and must
// never resolve a path outside the repository boundary. Import is the one
// place Norn runs anything, and it runs exactly one program with arguments it
// constructs itself.
//
// The validation below is what keeps trace content from becoming those
// arguments. These tests are adversarial about it, because a reference that
// escaped validation would let a hostile trace choose what git does.

@(test)
only_hex_object_names_are_accepted :: proc(t: ^testing.T) {
	// A commit reference from a trace is untrusted input. Accepting only hex
	// means it cannot become an option, a path, or a revision expression.
	valid := []string {
		"3c146e0",
		"3c146e0a5f2b1d8e9c4a7f6b2d1e8c9a4f7b6d2e",
		"ABCDEF01",
	}
	for value in valid {
		testing.expectf(t, api.is_hex_object_name(value), "%q should be accepted", value)
	}

	hostile := []string {
		"",
		"abc",                            // too short to be an object name
		"--upload-pack=/bin/sh",          // an option
		"HEAD",                           // a revision expression
		"HEAD~1",
		"main",
		"3c146e0; rm -rf /",              // a shell fragment
		"3c146e0 --output=/etc/passwd",
		"../../../etc/passwd",
		"3c146e0\nrm -rf /",
		"$(whoami)",
		"`id`",
	}
	for value in hostile {
		testing.expectf(t, !api.is_hex_object_name(value), "%q must be rejected", value)
	}
}

@(test)
only_safe_relative_paths_are_accepted :: proc(t: ^testing.T) {
	// The same rules as core's normalization, restated at this boundary
	// because this is where a path becomes an argument to another program.
	valid := []string{"src/main.odin", "README.md", "a/b/c/d.txt"}
	for value in valid {
		testing.expectf(t, api.is_safe_relative_path(value), "%q should be accepted", value)
	}

	hostile := []string {
		"",
		"/etc/passwd",              // absolute
		"../outside",               // escapes the repository
		"src/../../etc/passwd",
		"src/./main.odin",          // not normalized
		"src//main.odin",
		`src\main.odin`,            // a Windows separator
		"C:/Users/someone",         // a drive prefix
		"--output=/tmp/evil",       // reads as an option
		"-o",
		"src/main.odin\x00.txt",    // an embedded NUL
	}
	for value in hostile {
		testing.expectf(t, !api.is_safe_relative_path(value), "%q must be rejected", value)
	}
}

@(test)
a_hostile_commit_reference_reads_nothing :: proc(t: ^testing.T) {
	// The end-to-end guarantee: even given a repository, a reference that
	// fails validation never reaches git.
	root, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		testing.fail_now(t, "could not determine the working directory")
	}
	defer delete(root, context.temp_allocator)

	hostile := []string{"--upload-pack=/bin/echo", "HEAD", "; touch /tmp/norn-should-not-exist"}
	for reference in hostile {
		content, ok := api.read_blob_at_commit(root, reference, "README.md")
		testing.expectf(t, !ok, "reference %q must be refused", reference)
		testing.expect(t, content == nil)
	}

	// Nothing was executed.
	testing.expect(
		t,
		!os.exists("/tmp/norn-should-not-exist"),
		"no command from a reference may run",
	)
}

@(test)
a_hostile_path_reads_nothing :: proc(t: ^testing.T) {
	root, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		testing.fail_now(t, "could not determine the working directory")
	}
	defer delete(root, context.temp_allocator)

	// A valid-looking commit with a path that escapes the repository.
	hostile := []string{"../../../etc/passwd", "/etc/passwd", "--output=/tmp/evil"}
	for path in hostile {
		content, ok := api.read_blob_at_commit(
			root,
			"3c146e0a5f2b1d8e9c4a7f6b2d1e8c9a4f7b6d2e",
			path,
		)
		testing.expectf(t, !ok, "path %q must be refused", path)
		testing.expect(t, content == nil)
	}
}

@(test)
a_missing_root_is_reported :: proc(t: ^testing.T) {
	_, err := api.inspect_repository("/nonexistent/repository/path")
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Not_Found)
}

@(test)
an_empty_root_is_rejected :: proc(t: ^testing.T) {
	_, err := api.inspect_repository("")
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invalid_Argument)
}

@(test)
a_directory_without_git_is_not_an_error :: proc(t: ^testing.T) {
	// docs/05 allows an import with no version control. The trace records that
	// rather than the importer refusing.
	temporary, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {
		testing.fail_now(t, "no temporary directory available")
	}
	defer delete(temporary, context.temp_allocator)

	repository, err := api.inspect_repository(temporary)
	defer api.repository_destroy(&repository)

	testing.expect(t, core.ok(err), "a plain directory must be importable")
	testing.expect(t, !repository.is_git)
	testing.expect_value(t, repository.head, "")
}

@(test)
this_repository_is_recognised :: proc(t: ^testing.T) {
	// Norn's own checkout is a convenient real git repository to read.
	root, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		testing.fail_now(t, "could not determine the working directory")
	}
	defer delete(root, context.temp_allocator)

	// Tests run from the package directory, so walk up to the repository root.
	candidate := root
	for _ in 0 ..< 4 {
		if os.is_dir(strings.concatenate({candidate, "/.git"}, context.temp_allocator)) {
			break
		}
		parent := parent_directory(candidate)
		if parent == candidate {
			break
		}
		candidate = parent
	}
	if !os.is_dir(strings.concatenate({candidate, "/.git"}, context.temp_allocator)) {
		testing.fail_now(t, "no git repository found to test against")
	}

	repository, err := api.inspect_repository(candidate)
	defer api.repository_destroy(&repository)

	testing.expect(t, core.ok(err))
	testing.expect(t, repository.is_git)
	testing.expect(t, repository.name != "", "the repository must have a name")
	testing.expectf(
		t,
		api.is_hex_object_name(repository.head),
		"HEAD %q must be an object name",
		repository.head,
	)
	testing.expect(t, repository.branch != "", "the branch must be reported")
}

@(private)
parent_directory :: proc(path: string) -> string {
	trimmed := strings.trim_suffix(path, "/")
	last := -1
	for index in 0 ..< len(trimmed) {
		if trimmed[index] == '/' {
			last = index
		}
	}
	if last <= 0 {
		return trimmed
	}
	return trimmed[:last]
}

@(test)
identity_carries_what_the_trace_records :: proc(t: ^testing.T) {
	repository := api.Repository {
		root = "/Users/someone/projects/norn",
		name = "norn",
		is_git = true,
		head = "3c146e0",
		branch = "master",
		dirty = true,
		case_sensitive = false,
	}

	identity := api.to_identity(&repository)

	testing.expect_value(t, identity.repository_name, "norn")
	testing.expect_value(t, identity.start_commit, "3c146e0")
	testing.expect_value(t, identity.branch, "master")
	testing.expect(t, identity.initially_dirty)
	testing.expect(t, !identity.case_sensitive)

	// The full path travels as the identity's path field, which the sink
	// redacts before it reaches the trace.
	testing.expect_value(t, identity.repository_path, "/Users/someone/projects/norn")
}
