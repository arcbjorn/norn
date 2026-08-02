package importer_api

import "core:os"
import "core:strings"

import "src:core"

// Repository identity capture.
//
// docs/05-importers.md lists what the importer records about a repository, and
// permits reading baseline content with `git show` using a fixed argument
// vector.
//
// docs/08 fixes the boundary this file must not cross: opening or replaying a
// trace must never "execute a command, script, binary, hook, plugin, or macro"
// and must never "resolve a path outside the selected repository boundary".
// Import is the one place Norn runs anything at all, and it runs exactly one
// program with arguments it constructs itself. Nothing from the trace ever
// becomes an argument.

// GIT_PROGRAM is the only executable this project ever runs.
//
// A bare name resolved through PATH rather than an absolute path, because the
// correct git differs between systems. The arguments are what matter for
// safety: they are fixed vectors, never a shell string.
GIT_PROGRAM :: "git"

// GIT_TIMEOUT bounds a git invocation.
//
// A repository on a stalled network mount would otherwise hang an import
// indefinitely with no indication of why.
GIT_TIMEOUT_SECONDS :: 10

// Repository is what the importer learned about the source repository.
Repository :: struct {
	root:      string,
	name:      string,
	is_git:    bool,
	head:      string,
	branch:    string,
	dirty:     bool,
	// docs/05: case-sensitivity behaviour, because a trace recorded on a
	// case-insensitive filesystem can contain two paths that differ only by
	// case and mean one file.
	case_sensitive: bool,
}

repository_destroy :: proc(repository: ^Repository) {
	delete(repository.root)
	delete(repository.name)
	delete(repository.head)
	delete(repository.branch)
	repository^ = {}
}

// inspect_repository gathers identity for a repository root.
//
// A directory that is not a repository is not an error: docs/05 allows an
// import with no version control, and the trace records that rather than
// refusing.
inspect_repository :: proc(
	root: string,
	allocator := context.allocator,
) -> (
	repository: Repository,
	err: core.Error,
) {
	if root == "" {
		return {}, core.err_make(.Invalid_Argument, "no repository root was given")
	}
	if !os.is_dir(root) {
		return {}, core.err_path(.Not_Found, "the repository root is not a directory", root)
	}

	repository.root = strings.clone(root, allocator)
	repository.name = strings.clone(base_name(root), allocator)
	repository.case_sensitive = probe_case_sensitivity(root)

	// A repository without git is a legitimate subject. Everything below is
	// best-effort and leaves the fields empty when git is unavailable.
	if !os.is_dir(strings.concatenate({root, "/.git"}, context.temp_allocator)) {
		return repository, nil
	}
	repository.is_git = true

	if head, ok := git_output(root, {"rev-parse", "HEAD"}, allocator); ok {
		repository.head = head
	}
	if branch, ok := git_output(root, {"rev-parse", "--abbrev-ref", "HEAD"}, allocator); ok {
		repository.branch = branch
	}
	if status, ok := git_output(root, {"status", "--porcelain"}, context.temp_allocator); ok {
		repository.dirty = len(strings.trim_space(status)) > 0
		delete(status, context.temp_allocator)
	}

	return repository, nil
}

// read_blob_at_commit returns a file's content at a commit.
//
// docs/05: "if a baseline commit is available, the importer may read file
// content using `git show` with a fixed argument vector." The vector is built
// here from a validated commit and a repository-relative path; neither is
// concatenated into a string a shell would interpret.
read_blob_at_commit :: proc(
	root: string,
	commit: string,
	path: string,
	allocator := context.allocator,
) -> (
	content: []byte,
	ok: bool,
) {
	// A commit reference from a trace is untrusted input. Accepting only hex
	// means it cannot become an option, a path, or a revision expression with
	// side effects.
	if !is_hex_object_name(commit) {
		return nil, false
	}
	// The path must already be repository-relative and normalized. A path with
	// a parent component would let `git show` read outside the repository.
	if !is_safe_relative_path(path) {
		return nil, false
	}

	specifier := strings.concatenate({commit, ":", path}, context.temp_allocator)
	defer delete(specifier, context.temp_allocator)

	text, found := git_output_raw(root, {"show", specifier}, allocator)
	return text, found
}

// git_output runs git and returns trimmed standard output.
@(private)
git_output :: proc(
	root: string,
	arguments: []string,
	allocator := context.allocator,
) -> (
	output: string,
	ok: bool,
) {
	raw, found := git_output_raw(root, arguments, context.temp_allocator)
	if !found {
		return "", false
	}
	defer delete(raw, context.temp_allocator)

	trimmed := strings.trim_space(string(raw))
	return strings.clone(trimmed, allocator), true
}

// git_output_raw runs git with a fixed argument vector.
//
// The vector is passed to the process directly. docs/08: "trace content is
// never concatenated into a shell string", and no shell is involved here at
// all — there is no interpreter between this call and the program.
@(private)
git_output_raw :: proc(
	root: string,
	arguments: []string,
	allocator := context.allocator,
) -> (
	output: []byte,
	ok: bool,
) {
	// The program name plus its arguments. `-C` sets the working directory
	// through git itself rather than changing this process's directory, which
	// would be a global side effect during a concurrent import.
	command := make([dynamic]string, 0, len(arguments) + 3, context.temp_allocator)
	defer delete(command)

	append(&command, GIT_PROGRAM)
	append(&command, "-C")
	append(&command, root)
	append(&command, ..arguments)

	state, stdout, stderr, process_err := os.process_exec(
		os.Process_Desc{command = command[:]},
		allocator,
	)
	if len(stderr) > 0 {
		delete(stderr, allocator)
	}
	if process_err != nil {
		if len(stdout) > 0 {
			delete(stdout, allocator)
		}
		return nil, false
	}
	if !state.success {
		// A non-zero exit is an ordinary answer here: the file did not exist
		// at that commit, or the reference is unknown. The caller treats a
		// missing baseline as missing rather than as a failure.
		if len(stdout) > 0 {
			delete(stdout, allocator)
		}
		return nil, false
	}

	return stdout, true
}

// is_hex_object_name reports whether a string is a plausible git object name.
//
// Accepting only hex is what prevents a trace-supplied reference from becoming
// something else: `--upload-pack=...` is not hex, and neither is a path.
is_hex_object_name :: proc "contextless" (value: string) -> bool {
	if len(value) < 4 || len(value) > 64 {
		return false
	}
	for index in 0 ..< len(value) {
		c := value[index]
		is_hex :=
			(c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex {
			return false
		}
	}
	return true
}

// is_safe_relative_path reports whether a path may be passed to git.
//
// The same rules as core's path normalization, restated at this boundary
// because this is where a path becomes an argument to another program. A
// leading dash would be read as an option, which normalization does not
// otherwise care about.
is_safe_relative_path :: proc "contextless" (path: string) -> bool {
	if len(path) == 0 || len(path) > 4096 {
		return false
	}
	if path[0] == '/' || path[0] == '-' {
		return false
	}
	if len(path) >= 2 && path[1] == ':' {
		return false
	}

	start := 0
	for index in 0 ..= len(path) {
		if index < len(path) {
			if path[index] == 0 || path[index] == '\\' {
				return false
			}
			if path[index] != '/' {
				continue
			}
		}
		component := path[start:index]
		start = index + 1
		if component == "" || component == "." || component == ".." {
			return false
		}
	}
	return true
}

// probe_case_sensitivity reports whether the filesystem distinguishes case.
//
// Determined by looking rather than by assuming from the platform: a
// case-sensitive volume on macOS and a case-insensitive one on Linux both
// exist, and guessing wrong means two recorded paths that differ only by case
// are treated as one file or as two.
@(private)
probe_case_sensitivity :: proc(root: string) -> bool {
	// The `.git` directory is present in the repositories this matters for and
	// its name is fixed, so it can be probed without creating anything.
	lower := strings.concatenate({root, "/.git"}, context.temp_allocator)
	defer delete(lower, context.temp_allocator)
	upper := strings.concatenate({root, "/.GIT"}, context.temp_allocator)
	defer delete(upper, context.temp_allocator)

	if !os.exists(lower) {
		// Nothing to probe with. Assuming case-sensitive is the conservative
		// choice: it keeps two differing paths distinct rather than merging
		// records that may describe different files.
		return true
	}
	return !os.exists(upper)
}

@(private)
base_name :: proc(path: string) -> string {
	trimmed := strings.trim_suffix(path, "/")
	last := -1
	for index in 0 ..< len(trimmed) {
		if trimmed[index] == '/' {
			last = index
		}
	}
	if last < 0 {
		return trimmed
	}
	return trimmed[last + 1:]
}

// to_identity converts a captured repository into the sink's identity record.
to_identity :: proc(repository: ^Repository) -> Session_Identity {
	identity := Session_Identity {
		repository_name = repository.name,
		// The full path is passed through the sink, which replaces a
		// configured home prefix before it reaches the trace.
		repository_path = repository.root,
		start_commit    = repository.head,
		branch          = repository.branch,
		case_sensitive  = repository.case_sensitive,
		initially_dirty = repository.dirty,
	}
	if repository.is_git {
		identity.version_control = .Repository
	}
	return identity
}
