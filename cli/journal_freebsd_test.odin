#+build freebsd
package leita_cli

import "core:strings"
import "core:testing"

@(test)
freebsd_journal_does_not_claim_a_native_change_history :: proc(t: ^testing.T) {
	for verb in ([]string{"status", "on", "run", "off"}) {
		b := strings.builder_make(context.temp_allocator)
		code := journal_dispatch({}, {verb}, strings.to_writer(&b))
		want := EXIT_ERROR if verb == "on" || verb == "run" else EXIT_OK
		testing.expect_value(t, code, want)
		testing.expect(t, strings.contains(strings.to_string(b), "whole tree on every scan"))
	}
}
