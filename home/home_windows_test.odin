#+build windows
package home

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// The profile directory is USERPROFILE, and the id is this account's SID.
@(test)
user_is_the_profile_and_the_account_sid :: proc(t: ^testing.T) {
	was := strings.clone(os.get_env("USERPROFILE", context.temp_allocator), context.temp_allocator)
	testing.expect(t, os.set_env("USERPROFILE", `C:\Users\elsewhere`) == nil)
	defer os.set_env("USERPROFILE", was)

	u := user()
	defer user_destroy(&u)
	testing.expect_value(t, u.dir, `C:\Users\elsewhere`)
	testing.expect(t, strings.has_prefix(u.uid, "S-1-"), "a SID string")
	testing.expect(t, strings.contains(u.uid, "-"), "with at least one authority")
}

// sid_is_stable_on_a_skewed_temporary_arena reads this process's SID once,
// onto the heap, then again after a pad of 0..7 bytes on the temporary arena.
// TokenUser contains a pointer. A pad whose length is not a multiple of 4
// leaves an alignment-1 buffer off the 32-bit boundary that call requires.
// The account id does not depend on the profile path, so the environment
// stays as the runner left it.
@(test)
sid_is_stable_on_a_skewed_temporary_arena :: proc(t: ^testing.T) {
	// Two alignment-1 allocations do not land the second on a 32-bit boundary.
	// That is the skew the pads below rely on.
	mem.free_all(context.temp_allocator)
	first := make([]byte, 1, context.temp_allocator)
	second := make([]byte, 1, context.temp_allocator)
	testing.expect(t, len(first) == 1 && len(second) == 1, "skew probe")
	testing.expectf(
		t,
		uintptr(raw_data(second)) % 4 != 0,
		"alignment-1 buffer at %v",
		uintptr(raw_data(second)),
	)

	mem.free_all(context.temp_allocator)
	expected := sid()
	defer delete(expected)
	testing.expect(t, strings.has_prefix(expected, "S-1-"), "a SID string")

	for offset in 0 ..< 8 {
		mem.free_all(context.temp_allocator)
		if offset > 0 {
			pad := make([]byte, offset, context.temp_allocator)
			testing.expectf(t, len(pad) == offset, "pad %d", offset)
		}
		got := sid()
		testing.expectf(t, got == expected, "sid pad %d: %q", offset, got)
		delete(got)

		mem.free_all(context.temp_allocator)
		if offset > 0 {
			pad := make([]byte, offset, context.temp_allocator)
			testing.expectf(t, len(pad) == offset, "pad %d before user", offset)
		}
		u := user(context.temp_allocator)
		testing.expectf(t, u.uid == expected, "user pad %d: %q", offset, u.uid)
		user_destroy(&u, context.temp_allocator)
	}
}
