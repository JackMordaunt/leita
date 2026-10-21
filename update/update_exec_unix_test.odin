#+build linux, darwin
package update

import "core:os"
import "core:strings"
import "core:testing"

import "jm:sh"

// The file apply wrote is executed, which is the relaunch the updater itself
// does not do. Windows has no shell script to stand in for the binary here.
@(test)
the_installed_executable_is_the_one_that_runs :: proc(t: ^testing.T) {
	old_body := "#!/bin/sh\necho OLD-LEITA\n"
	new_body := "#!/bin/sh\necho NEW-LEITA\n"
	f := fixture(t, old_body, new_body, "v1.1.0")
	defer os.remove_all(f.root)
	// The installed file keeps the mode it had. A shell stand-in has to be
	// executable before apply, which is what a real binary already is.
	testing.expect_value(
		t,
		os.change_mode(f.exe, os.Permissions_All - os.Permissions_Write_All + {.Write_User}),
		nil,
	)
	r := apply(config(&f))
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, read(f.exe), new_body)
	ran := sh.exec({f.exe}, {}, context.temp_allocator)
	testing.expectf(t, ran.ok, "exit %d: %s %v", ran.code, ran.stderr, ran.err)
	testing.expect_value(t, strings.trim_space(ran.stdout), "NEW-LEITA")
}
