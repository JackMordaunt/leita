package walk

import "core:strings"
import "core:testing"
import "core:unicode/utf16"

@(test)
test_utf16_len_matches_the_encoder :: proc(t: ^testing.T) {
	samples := []string{"", "a", "字", "😀", "a字😀", `\\?\C:\Windows`}
	for text in samples {
		buf := make([]u16, len(text) + 1, context.temp_allocator)
		n := utf16.encode_string(buf[:len(text)], text)
		testing.expect_value(t, utf16_len(text), n)
	}
	flat := strings.repeat("n", UNICODE_PATH_MAX, context.temp_allocator)
	testing.expect_value(t, utf16_len(flat), UNICODE_PATH_MAX)
}

// A path is cut into pieces one UNICODE_STRING can hold, on UTF-16 units, at a
// separator. The rest is relative. A name with no separator inside the limit
// is refused rather than split through a character.
@(test)
test_a_windows_path_is_cut_on_utf16_units :: proc(t: ^testing.T) {
	testing.expect_value(t, UNICODE_PATH_MAX, 32767)

	expect_wide_cut(t, `\\?\C:\Windows`, 100, `\\?\C:\Windows`, "", true)
	expect_wide_cut(t, `ab\cd\ef`, 5, "ab", `cd\ef`, true)
	expect_wide_cut(t, `aaa\\bbb\\ccc`, 10, `aaa\\bbb`, "ccc", true)
	expect_wide_cut(t, "/aaaaaaaaaaaa/b", 10, "", "", false)
	// 😀 is one rune and two UTF-16 units, four UTF-8 bytes. A byte limit of 4
	// would split it; the cut is on units, so the piece stops at the slash.
	expect_wide_cut(t, "a\\😀\\b", 4, "a", "😀\\b", true)
	// Three CJK characters are three units and nine bytes, so they fit in 3.
	expect_wide_cut(t, "字字字", 3, "字字字", "", true)

	flat := strings.repeat("n", UNICODE_PATH_MAX, context.temp_allocator)
	expect_wide_cut(t, flat, UNICODE_PATH_MAX, flat, "", true)
	over := strings.concatenate({flat, "x"}, context.temp_allocator)
	expect_wide_cut(t, over, UNICODE_PATH_MAX, "", "", false)

	deep := deep_windows_path(t)
	piece, rest, ok := next_wide_piece(deep, UNICODE_PATH_MAX)
	testing.expect(t, ok, "a path past the Unicode limit was not cut")
	if !ok {
		return
	}
	testing.expect(t, utf16_len(deep) > UNICODE_PATH_MAX, "the deep path fits in one string")
	testing.expect(t, utf16_len(piece) <= UNICODE_PATH_MAX, "the piece exceeds UNICODE_STRING")
	testing.expect(t, rest != "" && rest[0] != '\\', "the rest was not relative")
	testing.expect(t, piece[len(piece) - 1] != '\\', "the piece ended on a separator")
	whole := strings.concatenate({piece, `\`, rest}, context.temp_allocator)
	testing.expect_value(t, whole, deep)
}

@(private)
expect_wide_cut :: proc(
	t: ^testing.T,
	path: string,
	limit: int,
	want_piece, want_rest: string,
	want_ok: bool,
) {
	piece, rest, ok := next_wide_piece(path, limit)
	testing.expect_value(t, ok, want_ok)
	if !want_ok {
		return
	}
	testing.expect_value(t, piece, want_piece)
	testing.expect_value(t, rest, want_rest)
	testing.expect(t, utf16_len(piece) <= limit, "a piece was past the limit")
	if rest == "" {
		return
	}
	end := piece[len(piece) - 1]
	testing.expect(t, end != '\\' && end != '/', "a piece ended on a separator")
	testing.expect(t, rest[0] != '\\' && rest[0] != '/', "a rest started on a separator")
}

// deep_windows_path is an extended path of 100-unit components, past
// UNICODE_PATH_MAX, with a separator inside every window of that size.
@(private)
deep_windows_path :: proc(t: ^testing.T) -> string {
	part := strings.repeat("d", 100, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `\\?\C:\`)
	for utf16_len(strings.to_string(b)) <= UNICODE_PATH_MAX {
		strings.write_string(&b, part)
		strings.write_string(&b, `\`)
	}
	path := strings.to_string(b)
	testing.expect(t, utf16_len(path) > UNICODE_PATH_MAX, "the fixture fits in one UNICODE_STRING")
	return path
}
