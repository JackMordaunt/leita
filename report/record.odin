package report

import "core:fmt"
import "core:strings"
import "core:time"

import "../history"

/*
write_record_json writes the changes leita made on disk (leita history --json) as
a JSON array, an action to a line, newest first as given: the members of
SCHEMA.md's leita.history/1 action, all always there, a detail that is empty as null.
*/
write_record_json :: proc(sb: ^strings.Builder, actions: []history.Action) {
	if len(actions) == 0 {
		strings.write_string(sb, "[]\n")
		return
	}
	strings.write_string(sb, "[\n")
	for a, i in actions {
		strings.write_string(sb, "  {\"taken\": ")
		json_time(sb, time.unix(a.taken, 0))
		fmt.sbprintf(sb, ", \"kind\": %q, ", history.ACTION_KINDS[a.kind])
		json_path(sb, a.path)
		strings.write_string(sb, ", \"bytes\": ")
		fmt.sbprintf(sb, "%d, \"failed\": %v, \"detail\": ", a.bytes, a.failed)
		json_string_or_null(sb, a.detail)
		strings.write_string(sb, "}")
		strings.write_string(sb, ",\n" if i + 1 < len(actions) else "\n")
	}
	strings.write_string(sb, "]\n")
}
