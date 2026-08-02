package export

import "core:os"
import "core:strings"

import "src:core"

// Writing an export to disk.
//
// docs/08-security.md: sensitive temporary files use user-only permissions and
// are atomically renamed. An export is exactly such a file — it may contain
// prompts, paths, and command lines — so it is written to a temporary name and
// renamed only once complete.

// REPORT_NAME and DATA_NAME are the fixed file names inside an export
// directory. Fixed rather than derived from the trace, because a name built
// from trace content would be attacker-controlled path input.
REPORT_NAME :: "report.html"
DATA_NAME   :: "export.json"

// DIRECTORY_PERMISSIONS and FILE_PERMISSIONS restrict an export to its owner.
//
// An export is the most sensitive artifact Norn produces: it is the one
// deliberately built to be moved somewhere else. Defaulting to owner-only
// means a shared machine does not disclose it before the user decides to.
DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
FILE_PERMISSIONS      :: os.Permissions{.Read_User, .Write_User}

// write_bundle renders both formats into `directory`.
//
// The directory must not already contain an export: overwriting one silently
// would destroy a previous report a user may still need, and there is no way
// to ask for confirmation from a library.
write_bundle :: proc(bundle: ^Bundle, directory: string) -> core.Error {
	if directory == "" {
		return core.err_make(.Invalid_Argument, "export requires a destination directory")
	}

	report_path := join_path(directory, REPORT_NAME)
	defer delete(report_path)
	data_path := join_path(directory, DATA_NAME)
	defer delete(data_path)

	if os.exists(report_path) || os.exists(data_path) {
		return core.err_path(
			.Invalid_Argument,
			"destination already contains an export; choose another directory",
			directory,
		)
	}

	if !os.exists(directory) {
		if err := os.make_directory(directory, DIRECTORY_PERMISSIONS); err != nil {
			return core.err_path(.Io_Failure, "could not create the export directory", directory)
		}
	}

	html := render_html(bundle)
	defer delete(html)
	json := render_json(bundle)
	defer delete(json)

	// Both files are written through temporaries and renamed, so an
	// interrupted export leaves no half-written report that looks complete.
	write_atomic(report_path, transmute([]byte)html) or_return
	if err := write_atomic(data_path, transmute([]byte)json); !core.ok(err) {
		// The report already landed; remove it so the directory does not hold
		// a partial export.
		os.remove(report_path)
		return err
	}

	return nil
}

@(private)
join_path :: proc(directory: string, name: string) -> string {
	trimmed := strings.trim_suffix(directory, "/")
	return strings.concatenate({trimmed, "/", name})
}

@(private)
write_atomic :: proc(path: string, content: []byte) -> core.Error {
	temporary := strings.concatenate({path, ".tmp"})
	defer delete(temporary)

	if os.write_entire_file(temporary, content) != nil {
		return core.err_path(.Io_Failure, "could not write the export file", path)
	}
	// Permissions are set before the rename so the file is never briefly
	// readable by others under its final name.
	if err := os.chmod(temporary, FILE_PERMISSIONS); err != nil {
		os.remove(temporary)
		return core.err_path(.Io_Failure, "could not restrict export permissions", path)
	}
	if os.rename(temporary, path) != nil {
		os.remove(temporary)
		return core.err_path(.Io_Failure, "could not publish the export file", path)
	}
	return nil
}
