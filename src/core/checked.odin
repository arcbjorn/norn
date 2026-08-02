package core

// Overflow-checked integer helpers.
//
// Every length, count, and offset that originates in untrusted input passes
// through these procedures before it is used for arithmetic or allocation.
// Callers must treat a false result as a hard parse failure, not as a value
// to clamp: a clamped size silently changes what the reader believes the file
// says.

// add_u64 returns a + b and whether the result is representable.
add_u64 :: proc "contextless" (a, b: u64) -> (sum: u64, ok: bool) {
	if b > max(u64) - a {
		return 0, false
	}
	return a + b, true
}

// mul_u64 returns a * b and whether the result is representable.
mul_u64 :: proc "contextless" (a, b: u64) -> (product: u64, ok: bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	if a > max(u64) / b {
		return 0, false
	}
	return a * b, true
}

// sub_u64 returns a - b and whether the result is non-negative.
sub_u64 :: proc "contextless" (a, b: u64) -> (difference: u64, ok: bool) {
	if b > a {
		return 0, false
	}
	return a - b, true
}

// add_int returns a + b and whether the result is representable.
add_int :: proc "contextless" (a, b: int) -> (sum: int, ok: bool) {
	if b > 0 && a > max(int) - b {
		return 0, false
	}
	if b < 0 && a < min(int) - b {
		return 0, false
	}
	return a + b, true
}

// mul_int returns a * b and whether the result is representable.
mul_int :: proc "contextless" (a, b: int) -> (product: int, ok: bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	result := a * b
	if result / b != a {
		return 0, false
	}
	return result, true
}

// to_int converts an untrusted u64 to int, rejecting values that do not fit.
// Slice lengths and offsets are int in Odin, so this is the single conversion
// point between file-format widths and in-memory indexing.
to_int :: proc "contextless" (value: u64) -> (result: int, ok: bool) {
	if value > u64(max(int)) {
		return 0, false
	}
	return int(value), true
}

// to_u32 converts an untrusted u64 to u32, rejecting values that do not fit.
to_u32 :: proc "contextless" (value: u64) -> (result: u32, ok: bool) {
	if value > u64(max(u32)) {
		return 0, false
	}
	return u32(value), true
}

// range_within reports whether [offset, offset + length) lies inside a region
// of `limit` bytes without overflowing. This is the bounds check used before
// every slice taken from a mapped or decoded buffer.
range_within :: proc "contextless" (offset, length, limit: u64) -> bool {
	end, ok := add_u64(offset, length)
	if !ok {
		return false
	}
	return end <= limit
}

// align_up rounds value up to the next multiple of alignment, which must be a
// power of two. Reports failure when rounding would overflow.
align_up :: proc "contextless" (value: u64, alignment: u64) -> (aligned: u64, ok: bool) {
	assert_contextless(alignment != 0 && (alignment & (alignment - 1)) == 0)
	mask := alignment - 1
	sum := add_u64(value, mask) or_return
	return sum & ~mask, true
}
