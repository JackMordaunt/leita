package leita_cli

import "core:strings"
import "core:testing"

@(test)
test_journal_usage_is_plain_when_piped :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	journal_print_usage({}, strings.to_writer(&b))
	testing.expect_value(t, strings.to_string(b), JOURNAL_USAGE)
}
