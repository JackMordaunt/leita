package leita_settings

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import jm_path "jm:path"

import "jm:sqlite3"

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

// COMPAT is card 749's on-disk fixtures, the files earlier builds wrote.
@(private)
COMPAT :: #directory + "/../cli/testdata/compat"

@(private)
copy_fixture :: proc(t: ^testing.T, dir, rel, name: string) -> (path: string, data: []u8) {
	src, _ := filepath.join({COMPAT, rel}, context.temp_allocator)
	read, err := os.read_entire_file(src, context.temp_allocator)
	testing.expectf(t, err == nil, "fixture %s is missing", rel)
	path, _ = filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, read) == nil, "could not copy the fixture")
	data = read
	return
}

@(private)
version_of :: proc(t: ^testing.T, st: ^Store) -> i64 {
	rows, err := sqlite3.query(st.db, "PRAGMA user_version", allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer sqlite3.finish(&rows)
	testing.expect(t, sqlite3.next(&rows), "user_version returned no row")
	return sqlite3.integer(rows, 0)
}

// A store written before user_version was stamped is this schema: it opens and
// keeps its rows, and opening it stamps this build. A new store is stamped too.
// Card 749's s7.db is that unversioned store.
@(test)
an_unversioned_store_opens_and_is_stamped :: proc(t: ^testing.T) {
	dir, derr := jm_path.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	path, _ := copy_fixture(t, dir, "settings/s7.db", FILE)
	st: Store
	testing.expect(t, open(&st, path) == nil, "a store with no user_version was refused")
	language, found := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, language, "de")
	testing.expect_value(t, version_of(t, &st), i64(SCHEMA_VERSION))
	close(&st)

	fresh, _ := filepath.join({dir, "new.db"}, context.temp_allocator)
	testing.expect(t, open(&st, fresh) == nil, "a new store did not open")
	testing.expect_value(t, version_of(t, &st), i64(SCHEMA_VERSION))
	close(&st)
}

// A store a newer build stamped is refused, naming both versions, and is not
// rewritten. Card 749's s-future.db is that store: user_version 99, plus a
// column and a table this build does not know.
@(test)
a_newer_store_is_refused :: proc(t: ^testing.T) {
	dir, derr := jm_path.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	path, before := copy_fixture(t, dir, "settings/s-future.db", FILE)
	st: Store
	err := open(&st, path)
	testing.expect(t, err != nil, "a newer store opened")
	if err == nil {
		close(&st)
		return
	}
	fault := err.(sqlite3.Fault) or_else sqlite3.Fault{}
	defer delete(fault.text)
	want := fmt.tprintf(
		"schema version 99 is newer than schema version %d, which this build reads",
		SCHEMA_VERSION,
	)
	testing.expect_value(t, fault.text, want)
	after, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect(t, slice.equal(after, before), "a newer store was rewritten")
	testing.expect(t, !os.exists(fmt.tprintf("%s-wal", path)), "a newer store was put in WAL")
	testing.expect(t, !os.exists(fmt.tprintf("%s-shm", path)), "a newer store was put in WAL")
}
