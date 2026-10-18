package walk

import "core:testing"

@(test)
test_clones_charge_data_once_keep_other_forks :: proc(t: ^testing.T) {
	c := clones_make(context.allocator)
	defer delete(c.paid)
	first, shared, ok := charge_clone(&c, {1, 10}, {8192, 7000}, 12288)
	testing.expect(t, ok && !shared)
	testing.expect_value(t, first, u64(12288))
	second: u64
	second, shared, ok = charge_clone(&c, {1, 10}, {8192, 7000}, 16384)
	testing.expect(t, ok && shared)
	testing.expect_value(t, second, u64(8192))
	other_volume: u64
	other_volume, shared, ok = charge_clone(&c, {2, 10}, {8192, 7000}, 12288)
	testing.expect(t, ok && !shared)
	testing.expect_value(t, other_volume, u64(12288))
}

@(test)
test_clones_keep_unknown_modified_and_inconsistent_allocation :: proc(t: ^testing.T) {
	c := clones_make(context.allocator)
	defer delete(c.paid)
	for key in ([]Clone_Key{{1, 0}, {1, 11}}) {
		got, shared, ok := charge_clone(&c, key, {8192, 7000}, 4096)
		testing.expect(t, ok && !shared)
		testing.expect_value(t, got, u64(4096))
	}
	charge_clone(&c, {1, 11}, {8192, 7000}, 8192)
	for data in ([]Clone_Data{{4096, 7000}, {8192, 6000}}) {
		got, shared, ok := charge_clone(&c, {1, 11}, data, 8192)
		testing.expect(t, ok && !shared)
		testing.expect_value(t, got, u64(8192))
	}
	paid, kept := c.paid[{1, 11}]
	testing.expect(t, kept, "the first complete measurement must remain")
	testing.expect_value(t, paid, Clone_Data{8192, 7000})
	got, shared, ok := charge_clone(&c, {1, 12}, {8192, 7000}, 8192)
	testing.expect(t, ok && !shared)
	testing.expect_value(t, got, u64(8192))
}
