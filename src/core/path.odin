package core

import "core:strings"
import "core:unicode/utf8"

// Repository path normalization and safety.
//
// docs/08-security.md: every recorded path becomes a repository-relative,
// `/`-separated path or it is rejected. Rejection is the correct outcome for a
// hostile path; there is no repair that preserves the trace's meaning, because
// a path that escapes the repository never described repository state.
//
// Normalization happens once, at the import boundary, before interning. Replay
// then operates on virtual paths and performs no filesystem resolution at all.

// Path_Rejection explains why a path was refused, so the import report can
// count reasons rather than emitting one opaque warning per record.
Path_Rejection :: enum u8 {
	None = 0,
	Empty,
	Absolute,
	Drive_Prefix,       // "C:" style Windows drive
	Unc_Prefix,         // "\\server\share"
	Parent_Component,   // ".." remains after normalization
	Current_Component,  // "." that is not the whole path
	Embedded_Nul,
	Invalid_Utf8,
	Too_Long,
	Empty_After_Normalization,
}

// rejection_name returns a stable identifier for reports and tests.
rejection_name :: proc "contextless" (reason: Path_Rejection) -> string {
	switch reason {
	case .None:                      return "none"
	case .Empty:                     return "empty"
	case .Absolute:                  return "absolute"
	case .Drive_Prefix:              return "drive_prefix"
	case .Unc_Prefix:                return "unc_prefix"
	case .Parent_Component:          return "parent_component"
	case .Current_Component:         return "current_component"
	case .Embedded_Nul:              return "embedded_nul"
	case .Invalid_Utf8:              return "invalid_utf8"
	case .Too_Long:                  return "too_long"
	case .Empty_After_Normalization: return "empty_after_normalization"
	}
	return "unknown"
}

// MAX_PATH_BYTES bounds a single normalized repository path. This is a trace
// model limit, not a filesystem limit: replay never opens these paths.
MAX_PATH_BYTES :: 4096

// normalize_path converts a recorded path into canonical repository-relative
// form, or reports why it cannot be represented.
//
// Accepted input uses either separator. The result uses `/`, has no empty,
// `.`, or `..` components, and is allocated with `allocator`. The caller owns
// the returned string.
//
// A leading `./` is dropped because it is a spelling of the same path. A
// leading `/` is rejected rather than stripped: an absolute path asserts a
// location outside the repository-relative namespace, and silently
// reinterpreting it as relative would invent a claim the trace never made.
normalize_path :: proc(
	input: string,
	allocator := context.allocator,
) -> (
	normalized: string,
	reason: Path_Rejection,
) {
	if len(input) == 0 {
		return "", .Empty
	}
	if len(input) > MAX_PATH_BYTES {
		return "", .Too_Long
	}
	if strings.contains_rune(input, 0) {
		return "", .Embedded_Nul
	}
	if !utf8.valid_string(input) {
		return "", .Invalid_Utf8
	}

	// Reject Windows-shaped roots before separator folding, because the
	// backslash forms become indistinguishable from ordinary components once
	// separators are unified.
	if strings.has_prefix(input, `\\`) {
		return "", .Unc_Prefix
	}
	if len(input) >= 2 && input[1] == ':' {
		c := input[0]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			return "", .Drive_Prefix
		}
	}
	if input[0] == '/' || input[0] == '\\' {
		return "", .Absolute
	}

	// Split on either separator and drop empty components, which collapses
	// repeated separators such as "a//b".
	components := make([dynamic]string, 0, 8, context.temp_allocator)
	defer delete(components)

	start := 0
	for i := 0; i <= len(input); i += 1 {
		at_end := i == len(input)
		if !at_end && input[i] != '/' && input[i] != '\\' {
			continue
		}
		component := input[start:i]
		start = i + 1

		switch component {
		case "":
			// Repeated or trailing separator; nothing to add.
		case ".":
			// A no-op component. Dropping it is safe because it cannot change
			// which file the path denotes.
		case "..":
			// `..` is never resolved against earlier components. Resolving it
			// would let "a/../../etc" reduce to a path outside the repository
			// whenever the prefix count happens to line up.
			return "", .Parent_Component
		case:
			append(&components, component)
		}
	}

	if len(components) == 0 {
		return "", .Empty_After_Normalization
	}

	joined := strings.join(components[:], "/", allocator)
	return joined, .None
}

// is_normalized_path reports whether a path is already in canonical form.
// The codec uses this to validate paths read from a trace without allocating.
is_normalized_path :: proc "contextless" (path: string) -> bool {
	if len(path) == 0 || len(path) > MAX_PATH_BYTES {
		return false
	}
	if path[0] == '/' {
		return false
	}
	if len(path) >= 2 && path[1] == ':' {
		c := path[0]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			return false
		}
	}

	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i < len(path) {
			if path[i] == '\\' || path[i] == 0 {
				return false
			}
			if path[i] != '/' {
				continue
			}
		}
		component := path[start:i]
		start = i + 1
		if component == "" || component == "." || component == ".." {
			return false
		}
	}
	return true
}
