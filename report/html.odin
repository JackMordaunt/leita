package report

import "core:fmt"
import "core:strings"
import "core:time"

import "../human"
import "../kinds"
import "../reclaim"

/*
write_html writes r as one page that needs nothing else: its style inline, no
script, no font or image fetched, which its Content-Security-Policy also forbids,
since leita promises not to touch the network and a report is opened anywhere.
It follows the reader's light or dark setting and prints on white. Every path is
readable text, escaped.
*/
write_html :: proc(sb: ^strings.Builder, r: ^Report) {
	strings.write_string(sb, HTML_HEAD)
	strings.write_string(sb, "<title>Disk usage of ")
	html_text(sb, r.target)
	strings.write_string(sb, "</title>\n<style>")
	strings.write_string(sb, HTML_STYLE)
	strings.write_string(sb, "</style>\n</head>\n<body>\n<main>\n")

	strings.write_string(
		sb,
		"<header>\n<p class=\"eyebrow\">Disk usage report</p>\n<h1 class=\"path\">",
	)
	html_text(sb, r.target)
	strings.write_string(sb, "</h1>\n<p class=\"sub\">")
	if started := iso(r.started); started != "" {
		strings.write_string(sb, "Scanned <time>")
		strings.write_string(sb, started)
		strings.write_string(sb, "</time>, ")
	}
	fmt.sbprintf(sb, "in %.1f s</p>\n", time.duration_seconds(r.duration))
	strings.write_string(sb, "</header>\n")

	strings.write_string(sb, "<section class=\"facts\">\n<dl>\n")
	html_fact(sb, "On disk", human.bytes(r.bytes), fmt.tprintf("%d bytes", r.bytes))
	html_fact(sb, "Files", human.count(r.files), "")
	html_fact(sb, "Directories", human.count(r.directories), "")
	if space, ok := r.space.?; ok {
		html_fact(
			sb,
			"Volume free",
			fmt.tprintf("%s of %s", human.bytes(space.free), human.bytes(space.total)),
			fmt.tprintf("%d of %d bytes", space.free, space.total),
		)
	}
	if fs := FILESYSTEM_KEYS[r.filesystem]; fs != "" {
		html_fact(sb, "Filesystem", FILESYSTEM_NAMES[r.filesystem], "")
	}
	if r.volume != "" {
		html_fact(sb, "Volume", r.volume, "")
	}
	if c, ok := r.compared.?; ok {
		html_fact(
			sb,
			"Compared with",
			fmt.tprintf("%s, %s", iso(c.taken), human.bytes(c.bytes)),
			"",
		)
	}
	strings.write_string(sb, "</dl>\n")
	if r.compared == nil {
		strings.write_string(sb, "<p class=\"note\">No earlier scan to compare with.</p>\n")
	}
	strings.write_string(
		sb,
		"<p class=\"note\">Charged is a share of allocated space. Exact reclaim is what deleting that one entry frees, when that is known, including zero. Unknown is not zero. Deleting a folder does not free the charged total of what it holds.</p>\n",
	)
	if acct, ok := r.accounting.?; ok {
		strings.write_string(sb, "<p class=\"note\">")
		html_text(sb, accounting_line(acct))
		strings.write_string(sb, "</p>\n")
	}
	strings.write_string(sb, "</section>\n")

	html_entries(sb, r, "Largest directories", r.largest_directories)
	html_entries(sb, r, "Largest files", r.largest_files)

	strings.write_string(sb, "<section>\n<h2>By kind</h2>\n<table>\n<thead><tr>")
	strings.write_string(
		sb,
		"<th>Kind</th><th class=\"num\">Files</th><th class=\"num\">Charged</th><th class=\"share\">Share</th>",
	)
	strings.write_string(sb, "</tr></thead>\n<tbody>\n")
	for kind in kinds.Kind {
		k := r.kinds[kind]
		if k.bytes == 0 && k.files == 0 {
			continue
		}
		strings.write_string(sb, "<tr><td>")
		strings.write_string(sb, kinds.NAMES[kind])
		fmt.sbprintf(sb, "</td><td class=\"num\">%s</td>", human.count(k.files))
		html_size(sb, k.bytes)
		html_share(sb, r, k.bytes)
		strings.write_string(sb, "</tr>\n")
	}
	strings.write_string(sb, "</tbody>\n</table>\n</section>\n")

	if groups, ok := r.reclaim.?; ok {
		total: u64
		for g in groups {
			total += g.bytes
		}
		strings.write_string(sb, "<section>\n<h2>Reclaim</h2>\n<p class=\"lede\">")
		if len(groups) == 0 {
			strings.write_string(sb, "Nothing found that can be deleted and made again.")
		} else {
			fmt.sbprintf(
				sb,
				"%s is the charged share of what can be deleted and made again. Deleting a folder does not always free that share.",
				human.bytes(total),
			)
		}
		strings.write_string(sb, "</p>\n")
		for g in groups {
			strings.write_string(sb, "<h3>")
			strings.write_string(sb, reclaim.CATEGORY_NAMES[g.category])
			fmt.sbprintf(sb, " <span class=\"total\">%s</span></h3>\n", human.bytes(g.bytes))
			strings.write_string(sb, "<p class=\"reason\">")
			html_text(sb, reclaim.CATEGORY_REASONS[g.category])
			strings.write_string(sb, "</p>\n<table>\n<thead><tr><th class=\"rank\">#</th>")
			strings.write_string(
				sb,
				"<th>Path</th><th class=\"num\">Charged</th><th class=\"share\">Share</th><th class=\"num\">Exact reclaim</th></tr></thead>\n<tbody>\n",
			)
			for c, i in g.items {
				fmt.sbprintf(sb, "<tr><td class=\"rank\">%d</td><td class=\"path\">", i + 1)
				html_text(sb, c.path)
				strings.write_string(sb, "</td>")
				html_size(sb, c.bytes)
				html_share(sb, r, c.bytes)
				html_frees(sb, c.frees)
				strings.write_string(sb, "</tr>\n")
			}
			strings.write_string(sb, "</tbody>\n</table>\n")
		}
		strings.write_string(sb, "</section>\n")
	}

	strings.write_string(sb, "<footer>")
	html_text(sb, generated_by(r))
	strings.write_string(sb, "</footer>\n</main>\n</body>\n</html>\n")
}

@(private)
html_entries :: proc(sb: ^strings.Builder, r: ^Report, title: string, entries: []Entry) {
	compared := r.compared != nil
	fmt.sbprintf(sb, "<section>\n<h2>%s</h2>\n", title)
	if len(entries) == 0 {
		strings.write_string(sb, "<p class=\"note\">None.</p>\n</section>\n")
		return
	}
	strings.write_string(
		sb,
		"<table>\n<thead><tr><th class=\"rank\">#</th><th>Path</th><th>Kind</th>",
	)
	strings.write_string(sb, "<th class=\"num\">Charged</th><th class=\"share\">Share</th><th class=\"num\">Exact reclaim</th>")
	if compared {
		strings.write_string(sb, "<th class=\"num\">Change</th>")
	}
	strings.write_string(sb, "</tr></thead>\n<tbody>\n")
	for e, i in entries {
		fmt.sbprintf(sb, "<tr><td class=\"rank\">%d</td><td class=\"path\">", i + 1)
		html_text(sb, e.path)
		fmt.sbprintf(sb, "</td><td class=\"kind\">%s</td>", kinds.NAMES[e.kind])
		html_size(sb, e.bytes)
		html_share(sb, r, e.bytes)
		html_frees(sb, e.frees)
		if compared {
			if delta, ok := change(e); ok {
				class := "up" if delta > 0 else "down" if delta < 0 else "same"
				sign := "+" if delta > 0 else "\u2212" if delta < 0 else ""
				fmt.sbprintf(
					sb,
					"<td class=\"num %s\" title=\"%d bytes before\">%s%s</td>",
					class,
					e.was.?,
					sign,
					human.bytes(u64(abs(delta))),
				)
			} else {
				strings.write_string(
					sb,
					"<td class=\"num same\" title=\"Not kept in the scan compared with: under 1 MiB then, or not there\">new</td>",
				)
			}
		}
		strings.write_string(sb, "</tr>\n")
	}
	strings.write_string(sb, "</tbody>\n</table>\n</section>\n")
}

@(private)
html_fact :: proc(sb: ^strings.Builder, term, value, exact: string) {
	strings.write_string(sb, "<div><dt>")
	strings.write_string(sb, term)
	strings.write_string(sb, "</dt><dd")
	if exact != "" {
		strings.write_string(sb, " title=\"")
		html_text(sb, exact)
		strings.write_byte(sb, '"')
	}
	strings.write_byte(sb, '>')
	html_text(sb, value)
	strings.write_string(sb, "</dd></div>\n")
}

@(private)
html_frees :: proc(sb: ^strings.Builder, frees: Maybe(u64)) {
	if n, ok := frees.?; ok {
		html_size(sb, n)
		return
	}
	strings.write_string(sb, "<td class=\"num\">unknown</td>")
}

// accounting_line is the snapshot and delayed-purge sentence. It names no
// quantity as bytes a delete frees.
@(private)
accounting_line :: proc(a: Accounting) -> string {
	line: string
	switch a.snapshots {
	case .None:
		line = "No snapshot was found. A charged size is still not what deletion frees."
	case .Present:
		line = "A snapshot may still hold deleted data. A charged size is not what deletion frees."
	case .Unchecked:
		line = "Whether a snapshot retains deleted data was not checked. A charged size is not what deletion frees."
	}
	if n, ok := a.purgeable.?; ok {
		return fmt.tprintf("%s The volume may still purge %s later.", line, human.bytes(n))
	}
	if a.scan_order || a.logical {
		return fmt.tprintf("%s These charged sizes are estimates.", line)
	}
	return line
}

@(private)
html_size :: proc(sb: ^strings.Builder, bytes: u64) {
	fmt.sbprintf(sb, "<td class=\"num\" title=\"%d bytes\">%s</td>", bytes, human.bytes(bytes))
}

// html_share is a cell with a bar as long as bytes' share of the target, and
// the share as a number beside it.
@(private)
html_share :: proc(sb: ^strings.Builder, r: ^Report, bytes: u64) {
	pct := 100 * share(r, bytes)
	fmt.sbprintf(
		sb,
		"<td class=\"share\"><span class=\"bar\"><span style=\"width:%.2f%%\"></span></span><span class=\"pct\">%.1f%%</span></td>",
		pct,
		pct,
	)
}

// html_text writes s readable and escaped, for text or a quoted attribute.
@(private)
html_text :: proc(sb: ^strings.Builder, s: string) {
	text := readable(s)
	for i in 0 ..< len(text) {
		switch text[i] {
		case '&':
			strings.write_string(sb, "&amp;")
		case '<':
			strings.write_string(sb, "&lt;")
		case '>':
			strings.write_string(sb, "&gt;")
		case '"':
			strings.write_string(sb, "&quot;")
		case '\'':
			strings.write_string(sb, "&#39;")
		case:
			strings.write_byte(sb, text[i])
		}
	}
}

@(private)
HTML_HEAD :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<meta name="color-scheme" content="light dark">
<meta name="generator" content="leita">
`

@(private)
HTML_STYLE :: `
:root {
	--bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --soft: #f6f8fa;
	--bar: #2e64a6; --track: #e6ebf1; --up: #b35000; --down: #0550ae;
	color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
	:root {
		--bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --soft: #151b23;
		--bar: #4693f1; --track: #262c36; --up: #f69d50; --down: #6cb6ff;
	}
}
* { box-sizing: border-box; }
html { background: var(--bg); color: var(--fg); }
body {
	margin: 0; background: var(--bg); color: var(--fg);
	font: 14px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
	-webkit-text-size-adjust: 100%;
}
main { max-width: 1040px; margin: 0 auto; padding: 32px 16px 48px; }
header { border-bottom: 1px solid var(--line); padding-bottom: 16px; margin-bottom: 24px; }
.eyebrow { margin: 0; color: var(--muted); font-size: 12px; letter-spacing: .06em; text-transform: uppercase; }
h1 { margin: 4px 0; font-size: 22px; font-weight: 600; }
h2 { margin: 32px 0 8px; font-size: 17px; font-weight: 600; }
h3 { margin: 20px 0 2px; font-size: 14px; font-weight: 600; }
h3 .total { color: var(--muted); font-weight: 400; margin-left: 6px; }
.sub, .note, .reason, .lede { margin: 0; color: var(--muted); }
.reason { margin-bottom: 8px; }
.path {
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
	font-variant-ligatures: none; overflow-wrap: anywhere; word-break: break-all;
}
h1.path { font-size: 20px; }
dl { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px; margin: 0 0 8px; }
dl div { background: var(--soft); border: 1px solid var(--line); border-radius: 6px; padding: 10px 12px; }
dt { color: var(--muted); font-size: 12px; }
dd { margin: 2px 0 0; font-size: 16px; font-weight: 600; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { padding: 6px 8px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
th { color: var(--muted); font-size: 12px; font-weight: 600; border-bottom-width: 2px; }
td.path { font-size: 13px; }
.rank { width: 2.5em; color: var(--muted); text-align: right; }
.num { text-align: right; white-space: nowrap; }
.kind { white-space: nowrap; color: var(--muted); }
.share { width: 160px; white-space: nowrap; }
.bar { display: inline-block; width: 100px; height: 8px; margin-right: 8px; vertical-align: middle; background: var(--track); border-radius: 4px; overflow: hidden; }
.bar span { display: block; height: 100%; background: var(--bar); }
.pct { color: var(--muted); font-size: 12px; }
.up { color: var(--up); }
.down { color: var(--down); }
.same { color: var(--muted); }
footer { margin-top: 40px; padding-top: 12px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
@media print {
	:root {
		--bg: #ffffff; --fg: #000000; --muted: #444c56; --line: #c8d1da; --soft: #ffffff;
		--bar: #2e64a6; --track: #e6ebf1; --up: #9a4400; --down: #0550ae;
	}
	@page { margin: 14mm; }
	body { font-size: 10pt; }
	main { max-width: none; padding: 0; }
	h2 { break-after: avoid; }
	thead { display: table-header-group; }
	tr, dl div { break-inside: avoid; }
	.bar, .bar span { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
}
`
