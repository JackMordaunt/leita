package leita_settings

import jm_path "jm:path"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
a_setting_never_written_reads_as_absent :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, set(&st, LANGUAGE, "de") == nil)
	v, found := get(&st, THEME, context.temp_allocator)
	testing.expect(t, !found, "another key's value is not this one's")
	testing.expect_value(t, v, "")
	language, ok := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, language, "de")
}

@(test)
a_setting_set_again_replaces_the_one_before :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, set(&st, THEME, "dark") == nil)
	testing.expect(t, set(&st, LANGUAGE, "de") == nil)
	testing.expect(t, set(&st, THEME, "light") == nil)

	theme, ok := get(&st, THEME, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, theme, "light")
	language, _ := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect_value(t, language, "de")
}

@(test)
settings_outlast_the_connection_that_wrote_them :: proc(t: ^testing.T) {
	dir, derr := jm_path.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "data", FILE}, context.temp_allocator)

	{
		st: Store
		testing.expect(t, open(&st, path) == nil, "it makes its folder")
		testing.expect(t, set(&st, LANGUAGE, "ja") == nil)
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	language, ok := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, language, "ja")
}

// A store that never heard of automatic checks has no such key. Two
// connections cannot both claim the same check.
@(test)
one_of_two_stores_claims_the_check :: proc(t: ^testing.T) {
	dir, derr := jm_path.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, FILE}, context.temp_allocator)

	first, second: Store
	testing.expect(t, open(&first, path) == nil)
	testing.expect(t, open(&second, path) == nil)
	defer close(&first)
	defer close(&second)

	_, found := get(&first, UPDATES, context.temp_allocator)
	testing.expect(t, !found, "automatic checks are absent until chosen")

	won_a, err_a := replace_if(&first, UPDATE_CHECKED, "", "1700000000")
	testing.expect(t, err_a == nil)
	testing.expect(t, won_a)
	won_b, err_b := replace_if(&second, UPDATE_CHECKED, "", "1700000001")
	testing.expect(t, err_b == nil)
	testing.expect(t, !won_b, "the second window sees the first's check")
	got, ok := get(&second, UPDATE_CHECKED, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, got, "1700000000")

	// The window that has seen the new value can claim the next one.
	won_c, err_c := replace_if(&second, UPDATE_CHECKED, "1700000000", "1700086400")
	testing.expect(t, err_c == nil)
	testing.expect(t, won_c)
}
