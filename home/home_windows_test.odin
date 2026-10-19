#+build windows
package home

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
