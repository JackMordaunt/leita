package leita_app

import "core:strings"

// Keep persistence warnings separate from action notices: a full data volume
// must not stop scanning, and its explanation must survive the next action.
@(private)
storage_problem_set :: proc(problem: ^string, text: string) {
	delete(problem^)
	problem^ = strings.clone(text) if text != "" else ""
}

@(private)
storage_problem :: proc(d: ^Desk) -> string {
	settings_reason, history_reason := d.settings_problem, d.history_problem
	if d.settings != nil && d.settings.read_only {
		settings_reason = d.settings.read_only_reason
	}
	if d.history != nil && d.history.read_only {
		history_reason = d.history.read_only_reason
	}
	if settings_reason != "" && settings_reason == history_reason {
		return settings_reason
	}
	lines := make([dynamic]string, context.temp_allocator)
	if settings_reason != "" {
		append(&lines, say(d, .Settings_Unkept, settings_reason))
	}
	if history_reason != "" {
		append(&lines, say(d, .History_Unkept, history_reason))
	}
	return strings.join(lines[:], " ", context.temp_allocator)
}
