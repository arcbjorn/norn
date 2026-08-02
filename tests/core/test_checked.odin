package test_core

import "core:testing"
import "src:core"

@(test)
add_u64_detects_overflow :: proc(t: ^testing.T) {
	sum, ok := core.add_u64(1, 2)
	testing.expect(t, ok)
	testing.expect_value(t, sum, u64(3))

	_, ok = core.add_u64(max(u64), 1)
	testing.expect(t, !ok, "max + 1 must not report success")

	sum, ok = core.add_u64(max(u64), 0)
	testing.expect(t, ok)
	testing.expect_value(t, sum, max(u64))
}

@(test)
mul_u64_detects_overflow :: proc(t: ^testing.T) {
	product, ok := core.mul_u64(1 << 20, 1 << 20)
	testing.expect(t, ok)
	testing.expect_value(t, product, u64(1) << 40)

	_, ok = core.mul_u64(max(u64), 2)
	testing.expect(t, !ok)

	// Zero short-circuits and must never be reported as overflow.
	product, ok = core.mul_u64(0, max(u64))
	testing.expect(t, ok)
	testing.expect_value(t, product, u64(0))
}

@(test)
sub_u64_rejects_underflow :: proc(t: ^testing.T) {
	difference, ok := core.sub_u64(5, 3)
	testing.expect(t, ok)
	testing.expect_value(t, difference, u64(2))

	_, ok = core.sub_u64(3, 5)
	testing.expect(t, !ok)
}

@(test)
to_int_rejects_out_of_range :: proc(t: ^testing.T) {
	value, ok := core.to_int(1234)
	testing.expect(t, ok)
	testing.expect_value(t, value, 1234)

	_, ok = core.to_int(u64(max(int)) + 1)
	testing.expect(t, !ok, "a u64 beyond max(int) must not become a slice length")
}

@(test)
range_within_guards_bounds_and_overflow :: proc(t: ^testing.T) {
	testing.expect(t, core.range_within(0, 10, 10))
	testing.expect(t, core.range_within(5, 5, 10))
	testing.expect(t, !core.range_within(5, 6, 10), "range must not exceed the limit")

	// An offset near the top of the range plus a length must not wrap around
	// into a small value that appears to be in bounds.
	testing.expect(t, !core.range_within(max(u64) - 1, 4, 1 << 20))
}

@(test)
align_up_rounds_and_detects_overflow :: proc(t: ^testing.T) {
	aligned, ok := core.align_up(1, 64)
	testing.expect(t, ok)
	testing.expect_value(t, aligned, u64(64))

	// An already-aligned value must not move.
	aligned, ok = core.align_up(64, 64)
	testing.expect(t, ok)
	testing.expect_value(t, aligned, u64(64))

	aligned, ok = core.align_up(0, 64)
	testing.expect(t, ok)
	testing.expect_value(t, aligned, u64(0))

	_, ok = core.align_up(max(u64), 64)
	testing.expect(t, !ok)
}
