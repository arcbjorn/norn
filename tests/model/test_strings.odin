package test_model

import "core:fmt"
import "core:testing"
import "src:trace/model"

@(test)
empty_string_is_identifier_zero :: proc(t: ^testing.T) {
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	id, ok := model.string_intern(&table, "")
	testing.expect(t, ok)
	testing.expect_value(t, id, model.EMPTY_STRING)

	value, got := model.string_get(&table, model.EMPTY_STRING)
	testing.expect(t, got)
	testing.expect_value(t, value, "")

	// The reserved slot is not an interned string.
	testing.expect_value(t, model.string_table_count(&table), 1)
}

@(test)
interning_deduplicates_by_exact_bytes :: proc(t: ^testing.T) {
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	first, _ := model.string_intern(&table, "src/main.odin")
	second, _ := model.string_intern(&table, "src/main.odin")
	testing.expect_value(t, first, second)

	// Case and Unicode are not normalized: differing bytes are distinct
	// strings, because folding them would assert an equivalence the source
	// never stated.
	upper, _ := model.string_intern(&table, "SRC/MAIN.ODIN")
	testing.expect(t, upper != first, "case-folded strings must not be merged")

	testing.expect_value(t, model.string_table_count(&table), 3)
}

@(test)
interning_survives_buffer_growth :: proc(t: ^testing.T) {
	// The content index must not hold pointers into the byte buffer: appending
	// past its capacity reallocates, and any retained pointer would dangle.
	// Interning far beyond the initial 4096-byte capacity exercises that.
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	COUNT :: 4000
	ids: [COUNT]model.String_Id

	for index in 0 ..< COUNT {
		value := fmt.tprintf("repository/path/segment-%d/file.odin", index)
		id, ok := model.string_intern(&table, value)
		testing.expectf(t, ok, "interning entry %d failed", index)
		ids[index] = id
	}

	testing.expect_value(t, model.string_table_count(&table), COUNT + 1)

    // Every earlier string must still read back correctly and still
    // deduplicate against a fresh, equal string.
	for index in 0 ..< COUNT {
		expected := fmt.tprintf("repository/path/segment-%d/file.odin", index)

		value, got := model.string_get(&table, ids[index])
		testing.expectf(t, got, "entry %d could not be read back", index)
		testing.expectf(
			t,
			value == expected,
			"entry %d read back as %q, expected %q",
			index,
			value,
			expected,
		)

		again, ok := model.string_intern(&table, expected)
		testing.expectf(t, ok, "re-interning entry %d failed", index)
		testing.expectf(
			t,
			again == ids[index],
			"entry %d re-interned as %d, expected %d",
			index,
			again,
			ids[index],
		)
	}

	// Re-interning existing content must not have added rows.
	testing.expect_value(t, model.string_table_count(&table), COUNT + 1)
}

@(test)
interning_order_is_deterministic :: proc(t: ^testing.T) {
	// docs/05: identical input must produce identical canonical output. First-
	// use order is what makes identifiers reproducible across runs.
	inputs := []string{"beta", "alpha", "beta", "gamma", "alpha", "delta"}

	run :: proc(inputs: []string, out: ^[dynamic]model.String_Id) {
		table: model.String_Table
		model.string_table_init(&table)
		defer model.string_table_destroy(&table)
		for value in inputs {
			id, _ := model.string_intern(&table, value)
			append(out, id)
		}
	}

	first := make([dynamic]model.String_Id)
	defer delete(first)
	second := make([dynamic]model.String_Id)
	defer delete(second)

	run(inputs, &first)
	run(inputs, &second)

	testing.expect_value(t, len(first), len(second))
	for index in 0 ..< len(first) {
		testing.expectf(
			t,
			first[index] == second[index],
			"identifier %d differed between runs: %d vs %d",
			index,
			first[index],
			second[index],
		)
	}

	// "beta" was seen first, so it holds the first non-reserved identifier.
	testing.expect_value(t, first[0], model.String_Id(1))
	testing.expect_value(t, first[2], model.String_Id(1))
	testing.expect_value(t, first[1], model.String_Id(2))
}

@(test)
string_get_rejects_out_of_range_identifiers :: proc(t: ^testing.T) {
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	id, _ := model.string_intern(&table, "only")

	_, ok := model.string_get(&table, id + 1)
	testing.expect(t, !ok, "an identifier past the end must not resolve")

	_, ok = model.string_get(&table, model.String_Id(9999))
	testing.expect(t, !ok)
}

@(test)
intern_respects_total_byte_budget :: proc(t: ^testing.T) {
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	_, ok := model.string_intern(&table, "12345", 8)
	testing.expect(t, ok, "a string within the budget must be accepted")

	_, ok = model.string_intern(&table, "67890", 8)
	testing.expect(t, !ok, "exceeding the total byte budget must fail explicitly")
}

@(test)
reindex_validates_offsets :: proc(t: ^testing.T) {
	table: model.String_Table
	model.string_table_init(&table)
	defer model.string_table_destroy(&table)

	model.string_intern(&table, "alpha")
	model.string_intern(&table, "beta")

	testing.expect(t, model.string_table_reindex(&table), "a valid table must reindex")

	value, ok := model.string_get(&table, model.String_Id(2))
	testing.expect(t, ok)
	testing.expect_value(t, value, "beta")

	// An offset past the end of the byte buffer must be rejected rather than
	// producing a wild slice at every later lookup.
	table.offsets[len(table.offsets) - 1] = u32(len(table.bytes) + 100)
	testing.expect(t, !model.string_table_reindex(&table), "out-of-bounds offset must fail")
}
