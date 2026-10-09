package report

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../kinds"
import "../reclaim"

// SCHEMA names what write_json writes; SCHEMA.md describes it. A change a reader
// of the last one would misread takes a new number.
SCHEMA :: "estoile.report/1"

/*
write_json writes r as one JSON object (SCHEMA.md): sizes as integer bytes,
times as ISO 8601 in UTC, a share as a fraction of the target's bytes, and
anything unknown as null rather than left out, so every field is always there.
Indented two spaces, an entry to a line.
*/
write_json :: proc(sb: ^strings.Builder, r: ^Report) {
	strings.write_string(sb, "{\n")
	fmt.sbprintf(sb, "  \"schema\": %q,\n", SCHEMA)
	strings.write_string(sb, "  \"generated\": ")
	json_time(sb, r.generated)
	strings.write_string(sb, ",\n  \"generator\": {\"name\": \"estoile\", \"version\": ")
	json_string(sb, r.version)
	strings.write_string(sb, "},\n")

	strings.write_string(sb, "  \"target\": {")
	json_path(sb, r.target)
	strings.write_string(sb, ", \"volume\": ")
	json_string_or_null(sb, r.volume)
	strings.write_string(sb, ", \"filesystem\": ")
	json_string_or_null(sb, FILESYSTEM_KEYS[r.filesystem])
	strings.write_string(sb, ", \"engine\": ")
	json_string_or_null(sb, ENGINE_KEYS[r.engine])
	strings.write_string(sb, "},\n")

	strings.write_string(sb, "  \"scan\": {\"started\": ")
	json_time(sb, r.started)
	fmt.sbprintf(sb, ", \"duration\": \"PT%.3fS\"},\n", time.duration_seconds(r.duration))

	fmt.sbprintf(
		sb,
		"  \"totals\": {{\"bytes\": %d, \"files\": %d, \"directories\": %d}},\n",
		r.bytes,
		r.files,
		r.directories,
	)

	strings.write_string(sb, "  \"space\": ")
	if space, ok := r.space.?; ok {
		fmt.sbprintf(sb, "{{\"total\": %d, \"free\": %d}}", space.total, space.free)
	} else {
		strings.write_string(sb, "null")
	}
	strings.write_string(sb, ",\n  \"compared\": ")
	if c, ok := r.compared.?; ok {
		strings.write_string(sb, "{\"taken\": ")
		json_time(sb, c.taken)
		fmt.sbprintf(sb, ", \"bytes\": %d}}", c.bytes)
	} else {
		strings.write_string(sb, "null")
	}
	strings.write_string(sb, ",\n")

	json_entries(sb, r, "largest_directories", r.largest_directories)
	json_entries(sb, r, "largest_files", r.largest_files)

	strings.write_string(sb, "  \"kinds\": [")
	for kind, i in kinds.Kind {
		k := r.kinds[kind]
		strings.write_string(sb, ",\n    " if i > 0 else "\n    ")
		fmt.sbprintf(
			sb,
			"{{\"kind\": %q, \"name\": %q, \"bytes\": %d, \"files\": %d, \"share\": %.6f}}",
			KIND_KEYS[kind],
			kinds.NAMES[kind],
			k.bytes,
			k.files,
			share(r, k.bytes),
		)
	}
	strings.write_string(sb, "\n  ],\n")

	strings.write_string(sb, "  \"reclaim\": ")
	if groups, ok := r.reclaim.?; ok {
		total: u64
		for g in groups {
			total += g.bytes
		}
		fmt.sbprintf(sb, "{{\"bytes\": %d, \"groups\": [", total)
		for g, i in groups {
			strings.write_string(sb, "," if i > 0 else "")
			strings.write_string(sb, "\n    {\"category\": ")
			json_string(sb, CATEGORY_KEYS[g.category])
			strings.write_string(sb, ", \"name\": ")
			json_string(sb, reclaim.CATEGORY_NAMES[g.category])
			strings.write_string(sb, ", \"reason\": ")
			json_string(sb, reclaim.CATEGORY_REASONS[g.category])
			fmt.sbprintf(sb, ", \"bytes\": %d, \"items\": [", g.bytes)
			for c, j in g.items {
				strings.write_string(sb, ",\n      {" if j > 0 else "\n      {")
				json_path(sb, c.path)
				fmt.sbprintf(sb, ", \"bytes\": %d, \"share\": %.6f}}", c.bytes, share(r, c.bytes))
			}
			strings.write_string(sb, "\n    ]}" if len(g.items) > 0 else "]}")
		}
		strings.write_string(sb, "\n  ]}" if len(groups) > 0 else "]}")
	} else {
		strings.write_string(sb, "null")
	}
	strings.write_string(sb, ",\n  \"generated_by\": ")
	json_string(sb, generated_by(r))
	strings.write_string(sb, "\n}\n")
}

@(private)
json_entries :: proc(sb: ^strings.Builder, r: ^Report, name: string, entries: []Entry) {
	fmt.sbprintf(sb, "  %q: [", name)
	for e, i in entries {
		strings.write_string(sb, ",\n    {" if i > 0 else "\n    {")
		json_path(sb, e.path)
		fmt.sbprintf(
			sb,
			", \"bytes\": %d, \"share\": %.6f, \"kind\": %q, \"bytes_before\": ",
			e.bytes,
			share(r, e.bytes),
			KIND_KEYS[e.kind],
		)
		if was, ok := e.was.?; ok {
			delta, _ := change(e)
			fmt.sbprintf(sb, "%d, \"change\": %d}}", was, delta)
		} else {
			strings.write_string(sb, "null, \"change\": null}")
		}
	}
	strings.write_string(sb, "\n  ],\n" if len(entries) > 0 else "],\n")
}

// json_path writes a "path" member, and a "path_base64" one beside it holding
// the exact bytes when they are not UTF-8.
@(private)
json_path :: proc(sb: ^strings.Builder, path: string) {
	strings.write_string(sb, "\"path\": ")
	json_string(sb, path)
	if !utf8.valid_string(path) {
		strings.write_string(sb, ", \"path_base64\": \"")
		strings.write_string(
			sb,
			base64.encode(transmute([]byte)path, allocator = context.temp_allocator),
		)
		strings.write_byte(sb, '"')
	}
}

@(private)
json_time :: proc(sb: ^strings.Builder, t: time.Time) {
	json_string_or_null(sb, iso(t))
}

@(private)
json_string_or_null :: proc(sb: ^strings.Builder, s: string) {
	if s == "" {
		strings.write_string(sb, "null")
	} else {
		json_string(sb, s)
	}
}

// json_string writes s as a JSON string: a quote, a backslash and every C0
// control escaped, and each byte that is not UTF-8 as U+FFFD, since RFC 8259
// section 8.1 has JSON exchanged between systems be UTF-8.
@(private)
json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i := 0; i < len(s); {
		r, size := utf8.decode_rune_in_string(s[i:])
		switch {
		case r == utf8.RUNE_ERROR && size == 1:
			strings.write_string(sb, `\ufffd`)
		case r == '"':
			strings.write_string(sb, `\"`)
		case r == '\\':
			strings.write_string(sb, `\\`)
		case r == '\n':
			strings.write_string(sb, `\n`)
		case r == '\r':
			strings.write_string(sb, `\r`)
		case r == '\t':
			strings.write_string(sb, `\t`)
		case r < 0x20 || r == 0x7f:
			fmt.sbprintf(sb, `\u%04x`, r)
		case:
			strings.write_string(sb, s[i:i + size])
		}
		i += size
	}
	strings.write_byte(sb, '"')
}
