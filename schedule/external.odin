package leita_schedule

import "core:path/filepath"
import "core:strings"

// external_cron_line is an example for a FreeBSD user crontab, never an install.
// Shell quoting protects argv. FreeBSD cron first consumes escaped backslashes
// and percent signs, so those are escaped after shell quoting:
// https://github.com/freebsd/freebsd-src/blob/releng/14.3/usr.sbin/cron/cron/do_command.c
external_cron_line :: proc(
	argv: []string,
	allocator := context.temp_allocator,
) -> (
	line, problem: string,
) {
	if len(argv) == 0 || !filepath.is_abs(argv[0]) {
		return "", "external scheduling needs an absolute program path"
	}
	shell := strings.builder_make(context.temp_allocator)
	for arg, i in argv {
		if strings.contains_any(arg, "\x00\r\n") {
			return "", "external scheduling cannot represent a line break or NUL in an argument"
		}
		if i > 0 {strings.write_byte(&shell, ' ')}
		strings.write_byte(&shell, '\'')
		for c in transmute([]byte)arg {
			if c == '\'' {
				strings.write_string(&shell, "'\\''")
			} else {
				strings.write_byte(&shell, c)
			}
		}
		strings.write_byte(&shell, '\'')
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "0 * * * * ")
	for c in transmute([]byte)strings.to_string(shell) {
		if c == '%' || c == '\\' {strings.write_byte(&b, '\\')}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), ""
}
