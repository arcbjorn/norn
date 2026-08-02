package core

// Typed errors crossing package boundaries.
//
// docs/02-architecture.md requires a stable category, a human-readable
// message, a subject when available, and a recoverability signal. Provider
// error strings never become control flow: callers branch on Category, not on
// message text.

// Category is the stable, machine-comparable classification of a failure.
// Adding a category is a compatible change; renaming one is not.
Category :: enum u16 {
	None = 0,

	// Input container and record problems.
	Malformed_Container,
	Unsupported_Version,
	Unsupported_Feature,
	Checksum_Mismatch,
	Truncated_Input,
	Limit_Exceeded,
	Invalid_Reference,
	Invalid_Encoding,

	// Semantic problems in otherwise well-formed data.
	Invariant_Violation,
	Invalid_Path,

	// Environment problems.
	Io_Failure,
	Out_Of_Memory,
	Not_Found,
	Permission_Denied,

	// Caller problems.
	Invalid_Argument,
	Cancelled,
}

// Recoverability tells the UI whether an operation can be retried or whether
// the subject must be rejected outright.
Recoverability :: enum u8 {
	Fatal      = 0, // The trace or operation cannot be used.
	Degraded   = 1, // Partial results are usable and must be labeled as partial.
	Retryable  = 2, // A transient condition; the same call may succeed later.
}

// Subject identifies what the error is about. Exactly one variant is
// meaningful; None is used when the failure has no narrower subject than the
// operation itself.
Subject_Kind :: enum u8 {
	None = 0,
	Path,
	Byte_Offset,
	Record_Number,
	Event_Id,
	Chunk_Ordinal,
}

Subject :: struct {
	kind:   Subject_Kind,
	text:   string, // Borrowed; valid for the lifetime the producer documents.
	number: u64,
}

// Failure describes one error. `message` is a short, stable, human-readable
// sentence. `detail` carries backend or platform specifics for logs. Neither
// ever contains file content or secret material; see docs/08-security.md.
Failure :: struct {
	category:       Category,
	recoverability: Recoverability,
	subject:        Subject,
	message:        string,
	detail:         string,
}

// Error is the value returned across package boundaries: a Failure or nil.
//
// It is a Maybe rather than a bare struct so that `or_return` propagates it,
// which keeps the "do not discard errors" rule in docs/10 cheap to follow at
// every call site.
Error :: Maybe(Failure)

// ok reports whether the error represents success.
ok :: proc "contextless" (err: Error) -> bool {
	_, failed := err.?
	return !failed
}

// failure returns the underlying Failure, or a zeroed one when err is nil.
failure :: proc "contextless" (err: Error) -> Failure {
	value, has := err.?
	if !has {
		return Failure{}
	}
	return value
}

// error_category returns the category, or .None for success.
error_category :: proc "contextless" (err: Error) -> Category {
	value, has := err.?
	if !has {
		return .None
	}
	return value.category
}

// error_message returns the message, or an empty string for success.
error_message :: proc "contextless" (err: Error) -> string {
	value, has := err.?
	if !has {
		return ""
	}
	return value.message
}

// errorf-free constructors keep allocation out of the error path. Messages are
// static strings chosen by the raising site.

// err_make builds an error with no narrower subject.
err_make :: proc "contextless" (
	category: Category,
	message: string,
	recoverability := Recoverability.Fatal,
) -> Error {
	return Failure{category = category, recoverability = recoverability, message = message}
}

// err_at builds an error about a byte offset in the input being parsed.
err_at :: proc "contextless" (
	category: Category,
	message: string,
	offset: u64,
	recoverability := Recoverability.Fatal,
) -> Error {
	return Failure {
		category = category,
		recoverability = recoverability,
		message = message,
		subject = Subject{kind = .Byte_Offset, number = offset},
	}
}

// err_path builds an error about a repository-relative or filesystem path.
// The path string is borrowed and must outlive the error's use.
err_path :: proc "contextless" (
	category: Category,
	message: string,
	path: string,
	recoverability := Recoverability.Fatal,
) -> Error {
	return Failure {
		category = category,
		recoverability = recoverability,
		message = message,
		subject = Subject{kind = .Path, text = path},
	}
}

// err_record builds an error about a source record number.
err_record :: proc "contextless" (
	category: Category,
	message: string,
	record: u64,
	recoverability := Recoverability.Fatal,
) -> Error {
	return Failure {
		category = category,
		recoverability = recoverability,
		message = message,
		subject = Subject{kind = .Record_Number, number = record},
	}
}

// category_name returns a stable lowercase identifier for logs and machine
// readable CLI output. These strings are part of the CLI contract.
category_name :: proc "contextless" (category: Category) -> string {
	switch category {
	case .None:                 return "ok"
	case .Malformed_Container:  return "malformed_container"
	case .Unsupported_Version:  return "unsupported_version"
	case .Unsupported_Feature:  return "unsupported_feature"
	case .Checksum_Mismatch:    return "checksum_mismatch"
	case .Truncated_Input:      return "truncated_input"
	case .Limit_Exceeded:       return "limit_exceeded"
	case .Invalid_Reference:    return "invalid_reference"
	case .Invalid_Encoding:     return "invalid_encoding"
	case .Invariant_Violation:  return "invariant_violation"
	case .Invalid_Path:         return "invalid_path"
	case .Io_Failure:           return "io_failure"
	case .Out_Of_Memory:        return "out_of_memory"
	case .Not_Found:            return "not_found"
	case .Permission_Denied:    return "permission_denied"
	case .Invalid_Argument:     return "invalid_argument"
	case .Cancelled:            return "cancelled"
	}
	return "unknown"
}
