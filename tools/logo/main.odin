// The logo lab: a grid of candidate marks for estoile, drawn as vector paths
// in a 100x100 unit box so one mark reads at 16 px and at 400 px alike. Run
// as the child half of a jm:ui hot-reload split (see tools/logo/host and
// `just logo`): edit this file, the watcher rebuilds it, the window
// updates. Click a tile to inspect it at every size.
//
//	logo                       run as the subprocess
//	logo -dump                 the first frame's scene ops as text
//	logo -png build/logo.png   render the first frame headlessly
//	logo -size 922x1030 -png … at that window size (default 1440x960)
//	logo -dark -png …          in the dark scheme
//	logo -estoile -png …       the estoile round rather than the first
//	logo -svg branding         write the mark and hero SVGs, light and dark
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "jm:ui"
import "jm:ui/child"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import mark "../../gui/mark"

WIDTH  :: 1440
HEIGHT :: 960

// Font ids main registers: Primer's three weights in the default face, and
// a bold monospace face for the wordmark and the monogram.
FONTS     :: primer.Fonts {
	normal   = 0,
	medium   = 1,
	semibold = 2,
	mono     = 3,
}
FONT_MONO :: ops.Font_Id(3)
MONO_FILES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
	"/usr/share/fonts/TTF/JetBrainsMono-Bold.ttf",
	"C:/Windows/Fonts/consolab.ttf",
}

COLS :: 3

// State is what survives a hot-reload respawn.
State :: struct {
	dark:     bool,
	size:     int, // index into SIZES
	selected: int,
	accent:   int, // index into ACCENTS
	set:      int, // index into SETS
}

Model :: struct {
	using state: State,
	scheme:      primer.Scheme,
}

SIZE_NAMES := [?]string{"64", "100", "140", "180"}
SIZES := [?]f32{64, 100, 140, 180}

// Ink is the logo's own palette, separate from the lab's UI theme.
Ink :: struct {
	ink, accent, paper, soft: ops.Color,
}

ACCENT_NAMES := [?]string{"sea", "jade", "signal", "amber"}
ACCENTS := [?]ops.Color {
	{14, 116, 144, 255},
	{16, 185, 129, 255},
	{232, 93, 58, 255},
	{235, 160, 30, 255},
}

palette :: proc(m: ^Model) -> Ink {
	if m.dark {
		return {
			ink = {240, 238, 232, 255},
			accent = ACCENTS[m.accent],
			paper = {22, 22, 24, 255},
			soft = {70, 70, 74, 255},
		}
	}
	return {
		ink = {28, 27, 26, 255},
		accent = ACCENTS[m.accent],
		paper = {250, 250, 247, 255},
		soft = {200, 198, 192, 255},
	}
}

// invert swaps ink and paper: the mark on a dark tile.
invert :: proc(k: Ink) -> Ink {
	return {ink = k.paper, accent = k.accent, paper = k.ink, soft = k.soft}
}

// ---------------------------------------------------------------- paths

// The path helpers are the chosen mark's, in gui/mark; arc and sector are
// the other candidates' own.

on_circle :: mark.on_circle
rad       :: mark.rad

// arc is an open arc, for stroking.
arc :: proc(gtx: ^ui.Ctx, c: ops.Point, r, a0, a1: f32) -> ops.Path_Ref {
	b := mark.pb(gtx)
	mark.pb_move(&b, on_circle(c, r, a0))
	mark.pb_arc(&b, c, r, a0, a1)
	return mark.pb_done(gtx, &b)
}

// sector is the pie wedge at c from a0 to a1.
sector :: proc(gtx: ^ui.Ctx, c: ops.Point, r, a0, a1: f32) -> ops.Path_Ref {
	b := mark.pb(gtx)
	mark.pb_move(&b, c)
	mark.pb_line(&b, on_circle(c, r, a0))
	mark.pb_arc(&b, c, r, a0, a1)
	mark.pb_close(&b)
	return mark.pb_done(gtx, &b)
}

// ---------------------------------------------------------------- marks

Mark_Proc :: proc(gtx: ^ui.Ctx, k: Ink)

Mark :: struct {
	name: string,
	draw: Mark_Proc,
}

MARKS := [?]Mark {
	{"ping", mark_ping},
	{"sweep", mark_sweep},
	{"sunburst", mark_sunburst},
	{"slice", mark_slice},
	{"treemap", mark_treemap},
	{"largest first", mark_largest_first},
	{"echo", mark_echo},
	{"two-tone s", mark_two_tone_s},
	{"monogram", mark_monogram},
}

// WORDMARK is the name the candidates are shown beside.
WORDMARK :: "estoile"

// The sets: the first round of candidates, from which the sunburst was
// chosen, and the estoile round, from which the star of cells was.
SET_NAMES := [?]string{"first round", "estoile"}

marks_of :: proc(m: ^Model) -> []Mark {
	return ESTOILE_MARKS[:] if m.set == 1 else MARKS[:]
}

stroke_w :: proc(w: f32) -> ops.Stroke_Style {
	return {width = w, cap = .Round, join = .Round}
}

// draw_mark draws m with its 100x100 box scaled to size at `at`.
draw_mark :: proc(gtx: ^ui.Ctx, m: Mark, at: ops.Point, size: f32, k: Ink) {
	s := f64(size / 100)
	ops.transform_push(gtx.scene, {s, 0, 0, s, f64(at.x), f64(at.y)})
	m.draw(gtx, k)
	ops.transform_pop(gtx.scene)
}

// 1. A ping from the corner: a source and the wavefronts leaving it, the
// farthest one lit.
mark_ping :: proc(gtx: ^ui.Ctx, k: Ink) {
	o := ops.Point{22, 78}
	ops.fill(gtx.scene, ui.circle(o, 9), k.ink)
	for r, i in ([3]f32{28, 45, 62}) {
		ops.stroke(
			gtx.scene,
			arc(gtx, o, r, rad(-90), 0),
			k.accent if i == 2 else k.ink,
			stroke_w(9),
		)
	}
}

// 2. A radar scope: the ring, the sweep's wedge, and one return behind it.
mark_sweep :: proc(gtx: ^ui.Ctx, k: Ink) {
	c := ops.Point{50, 50}
	ops.stroke(gtx.scene, ui.circle(c, 39), k.ink, stroke_w(8))
	ops.fill(gtx.scene, sector(gtx, c, 31, rad(-110), rad(-40)), k.accent)
	ops.fill(gtx.scene, ui.circle(on_circle(c, 21, rad(35)), 6), k.ink)
}

// 3. The disk as Space Radar draws it: a hub and two rings of folders, one
// big one lit. The mark until the name changed; the star of cells grew
// from it.
mark_sunburst :: proc(gtx: ^ui.Ctx, k: Ink) {
	c := ops.Point{50, 50}
	GAP :: 3.5 // half the gap between two cells, degrees
	cells := [?][5]f32 {
		{18, 30, -90, 90, 0},
		{18, 30, 90, 198, 0},
		{18, 30, 198, 270, 0},
		{34, 45, -90, 25, 1},
		{34, 45, 25, 90, 0},
		{34, 45, 90, 160, 0},
	}
	ops.fill(gtx.scene, ui.circle(c, 13), k.ink)
	for cell in cells {
		ops.fill(
			gtx.scene,
			mark.band(gtx, c, cell[0], cell[1], rad(cell[2] + GAP), rad(cell[3] - GAP)),
			k.accent if cell[4] == 1 else k.ink,
		)
	}
}

// 4. A pie with its biggest share pulled out: what is using the disk.
mark_slice :: proc(gtx: ^ui.Ctx, k: Ink) {
	c := ops.Point{48, 54}
	ops.fill(gtx.scene, sector(gtx, c, 36, rad(-50), rad(240)), k.ink)
	mid := rad(275)
	ops.fill(gtx.scene, sector(gtx, on_circle(c, 8, mid), 36, rad(240), rad(310)), k.accent)
}

// 5. A squarified treemap: the other way to draw a disk, the biggest tile lit.
mark_treemap :: proc(gtx: ^ui.Ctx, k: Ink) {
	ops.fill(gtx.scene, ops.Round_Rect{{12, 12, 42, 76}, 8}, k.accent)
	ops.fill(gtx.scene, ops.Round_Rect{{59, 12, 29, 40}, 7}, k.ink)
	ops.fill(gtx.scene, ops.Round_Rect{{59, 57, 29, 14}, 5}, k.ink)
	ops.fill(gtx.scene, ops.Round_Rect{{59, 76, 12, 12}, 4}, k.ink)
	ops.fill(gtx.scene, ops.Round_Rect{{76, 76, 12, 12}, 4}, k.ink)
}

// 6. A listing sorted by size, the bars brainfold's mark is built from:
// the largest on top, lit.
mark_largest_first :: proc(gtx: ^ui.Ctx, k: Ink) {
	H :: 10
	widths := [?]f32{72, 56, 42, 30, 20}
	for w, i in widths {
		y := 18 + f32(i) * 16
		ops.fill(
			gtx.scene,
			ops.Round_Rect{{14, y - H / 2, w, H}, H / 2},
			k.accent if i == 0 else k.ink,
		)
	}
}

// 7. An echo trace: the ping, then its returns dying away.
mark_echo :: proc(gtx: ^ui.Ctx, k: Ink) {
	W :: 8
	heights := [?]f32{76, 22, 52, 16, 34, 12, 22}
	for h, i in heights {
		x := 14 + f32(i) * 12
		ops.fill(
			gtx.scene,
			ops.Round_Rect{{x - W / 2, 50 - h / 2, W, h}, W / 2},
			k.accent if i == 0 else k.ink,
		)
	}
}

// 8. A lowercase s of two arcs, the lower one lit: a wave and its echo.
mark_two_tone_s :: proc(gtx: ^ui.Ctx, k: Ink) {
	ops.stroke(gtx.scene, arc(gtx, {50, 33}, 17, rad(-15), rad(-270)), k.ink, stroke_w(11))
	ops.stroke(gtx.scene, arc(gtx, {50, 67}, 17, rad(-90), rad(165)), k.accent, stroke_w(11))
}

// 9. The app-icon baseline: a bold mono s knocked out of a rounded square.
mark_monogram :: proc(gtx: ^ui.Ctx, k: Ink) {
	ops.fill(gtx.scene, ops.Round_Rect{{8, 8, 84, 84}, 22}, k.ink)
	draw_mono_text(gtx, "s", {50, 50}, 70, k.paper, centered = true)
}

// X_HEIGHT is the mono face's x-height as a fraction of its size, near
// enough for JetBrains Mono and Consolas both.
X_HEIGHT :: 0.55

// draw_mono_text draws s in the mono face: top-left at pos, or, for
// lowercase without ascenders, its x-height centred on pos.
draw_mono_text :: proc(
	gtx: ^ui.Ctx,
	s: string,
	pos: ops.Point,
	size: f32,
	color: ops.Color,
	centered := false,
) {
	run := ui.shape(gtx.shaper, FONT_MONO, size, s, gtx.allocator)
	m := ui.metrics(gtx.shaper, FONT_MONO, size)
	p := pos
	if centered {
		p = {pos.x - run.advance / 2, pos.y + size * X_HEIGHT / 2 - m.ascent}
	}
	ops.glyphs(gtx.scene, ops.add_run(gtx.scene, run), {p.x, p.y + m.ascent}, color)
}

// ---------------------------------------------------------------- the pack

LIGHT :: Ink {
	ink   = {28, 27, 26, 255},
	paper = {250, 250, 247, 255},
}
DARK  :: Ink {
	ink   = {240, 238, 232, 255},
	paper = {22, 22, 24, 255},
}

// write_pack writes the chosen mark and the hero lockup as SVG, one of each
// per scheme, into dir: mark-{light,dark}.svg on a transparent ground, and
// hero-{light,dark}.svg with the wordmark beside the mark. `just branding`
// rasterises them.
write_pack :: proc(dir: string) -> bool {
	ok := true
	ok &&= write_svg(fmt.tprintf("%s/mark-light.svg", dir), mark_svg(LIGHT))
	ok &&= write_svg(fmt.tprintf("%s/mark-dark.svg", dir), mark_svg(DARK))
	ok &&= write_svg(fmt.tprintf("%s/hero-light.svg", dir), hero_svg(LIGHT))
	ok &&= write_svg(fmt.tprintf("%s/hero-dark.svg", dir), hero_svg(DARK))
	return ok
}

write_svg :: proc(path, body: string) -> bool {
	if err := os.write_entire_file(path, transmute([]byte)body); err != nil {
		fmt.eprintfln("%s: %v", path, err)
		return false
	}
	return true
}

mark_svg :: proc(k: Ink) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(
		&b,
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="512" height="512" role="img" aria-label="estoile">`,
	)
	mark.write_svg(&b, k.ink, mark.SEA)
	fmt.sbprint(&b, "</svg>\n")
	return strings.to_string(b)
}

// hero_svg is the lockup: the mark at 140 px and the wordmark in a mono
// face. The font-family names JetBrains Mono first and ends in the generic
// monospace; nothing is embedded, so the mark is the constant part.
hero_svg :: proc(k: Ink) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(
		&b,
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 660 200" width="660" height="200" role="img" aria-label="estoile">`,
	)
	fmt.sbprintln(&b, `  <g transform="translate(40 30) scale(1.4)">`)
	mark.write_svg(&b, k.ink, mark.SEA, "    ")
	fmt.sbprintln(&b, `  </g>`)
	fmt.sbprintfln(
		&b,
		`  <text x="210" y="130" font-family="JetBrains Mono, JetBrainsMono Nerd Font, SFMono-Regular, Menlo, Consolas, monospace" font-weight="700" font-size="96" fill="%s">estoile</text>`,
		mark.hex(k.ink),
	)
	fmt.sbprint(&b, "</svg>\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------- the lab

draw_tile :: proc(gtx: ^ui.Ctx, m: ^Model, i: int, k: Ink, tile: f32) {
	p := ui.widget_open(gtx, u64(i + 1))
	size := ops.Size{tile, tile + 30}
	rr := ops.Round_Rect{{0, 0, size.x, size.y}, 14}
	ops.fill(gtx.scene, rr, primer.color(.Bg_Color_Muted))
	if m.selected == i {
		ops.stroke(
			gtx.scene,
			ops.Round_Rect{{1, 1, size.x - 2, size.y - 2}, 13},
			k.accent,
			{width = 2},
		)
	}
	s := min(SIZES[m.size], tile - 20)
	draw_mark(gtx, marks_of(m)[i], {(tile - s) / 2, (tile - s) / 2}, s, k)
	ui.draw_text(
		gtx,
		fmt.tprintf("%d  %s", i + 1, marks_of(m)[i].name),
		{16, tile - 4},
		13,
		primer.color(.Fg_Color_Muted),
	)
	ops.input_area(gtx.scene, p.id, rr, {.Press})
	for e in ui.events(gtx, p.id) {
		if e.kind == .Press {
			m.selected = i
		}
	}
	ui.widget_close(gtx, &p, {size = size})
}

// draw_detail shows the selected mark at every size it must survive, the
// wordmark lockup, and the mark on inverted paper, in a w by h panel: the
// size row and the inverted card give up their largest pieces first as w
// shrinks.
draw_detail :: proc(gtx: ^ui.Ctx, m: ^Model, k: Ink, w, h: f32) {
	p := ui.widget_open(gtx)
	mk := marks_of(m)[m.selected]
	PAD :: 24
	inner := w - 2 * PAD
	ops.fill(gtx.scene, ops.Round_Rect{{0, 0, w, h}, 14}, primer.color(.Bg_Color_Muted))

	x, y: f32 = PAD, 22
	ui.draw_text(
		gtx,
		fmt.tprintf("%d  %s", m.selected + 1, mk.name),
		{x, y},
		20,
		primer.color(.Fg_Color_Default),
	)
	y += 48

	// sizes, bottom-aligned on one row; as many as fit
	sizes := [?]f32{16, 24, 32, 48, 96, 144}
	n, used, biggest := 0, f32(0), f32(0)
	for s in sizes {
		if used + s > inner {
			break
		}
		used += s + 14
		biggest = s
		n += 1
	}
	base := y + biggest
	for s in sizes[:n] {
		draw_mark(gtx, mk, {x, base - s}, s, k)
		ui.draw_text(gtx, fmt.tprintf("%.0f", s), {x, base + 8}, 12, primer.color(.Fg_Color_Muted))
		x += s + 14
	}
	y = base + 40

	// lockup: mark + wordmark
	x = PAD
	draw_mark(gtx, mk, {x, y}, 56, k)
	draw_mono_text(gtx, WORDMARK, {x + 70, y + 4}, min(48, (inner - 70) / 3.2), k.ink)
	y += 84

	// inverted paper: the big mark, the wordmark beside it, and when there
	// is room the two smallest sizes in the corner
	inv := invert(k)
	big := clamp(inner - 48 - 130, 64, 144)
	ih := big + 56
	ops.fill(gtx.scene, ops.Round_Rect{{PAD, y, inner, ih}, 16}, inv.paper)
	draw_mark(gtx, mk, {PAD + 24, y + 28}, big, inv)
	draw_mono_text(
		gtx,
		WORDMARK,
		{PAD + 24 + big + 14, y + ih - 28 - 40},
		min(32, (inner - 48 - big - 14) / 3.2),
		inv.ink,
	)
	if inner >= 400 {
		draw_mark(gtx, mk, {PAD + inner - 24 - 16, y + 24}, 16, inv)
		draw_mark(gtx, mk, {PAD + inner - 24 - 32, y + 56}, 32, inv)
	}

	ui.widget_close(gtx, &p, {size = {w, h}})
}

segments :: proc(gtx: ^ui.Ctx, names: []string) -> []primer.Segment {
	out := make([]primer.Segment, len(names), gtx.allocator)
	for n, i in names {
		out[i] = {
			label = n,
		}
	}
	return out
}

draw_toolbar_main :: proc(gtx: ^ui.Ctx, m: ^Model) {
	primer.heading(gtx, "estoile · logo lab", 3)
	ui.spacer(gtx, 12)
	primer.segmented_control(gtx, segments(gtx, SET_NAMES[:]), &m.set, "set", size = .Small)
	primer.checkbox(gtx, &m.dark, "dark")
	primer.text(gtx, "size", color = primer.color(.Fg_Color_Muted))
	primer.segmented_control(gtx, segments(gtx, SIZE_NAMES[:]), &m.size, "size", size = .Small)
}

draw_toolbar_accent :: proc(gtx: ^ui.Ctx, m: ^Model) {
	primer.segmented_control(
		gtx,
		segments(gtx, ACCENT_NAMES[:]),
		&m.accent,
		"accent",
		size = .Small,
	)
}

// The lab fits whatever window it is given: the detail panel takes about a
// third of the width, the grid the rest, and the tiles shrink until the
// three rows fit the height. Below 1100 px the toolbar wraps to two rows.
draw_lab :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	ui.restore_struct(gtx, &m.state)
	theme: primer.Theme = m.dark ? .Dark : .Light
	m.scheme = primer.theme_scheme(theme)
	primer.use(&m.scheme, theme)
	primer.use_fonts(FONTS)
	k := palette(m)
	ops.fill(
		gtx.scene,
		ops.Rect{0, 0, gtx.constraints.max.x, gtx.constraints.max.y},
		primer.color(.Bg_Color_Default),
	)

	MARGIN :: 20
	GAP    :: 12
	avail := ops.Size{gtx.constraints.max.x - 2 * MARGIN, gtx.constraints.max.y - 2 * MARGIN}
	narrow := avail.x < 1100
	toolbar_h: f32 = 88 if narrow else 40
	body_h := avail.y - toolbar_h - 16
	detail_w := clamp(avail.x * 0.36, 320, 560)
	grid_w := avail.x - 24 - detail_w
	rows := (len(marks_of(m)) + COLS - 1) / COLS
	tile := min(
		(grid_w - f32(COLS - 1) * GAP) / COLS,
		(body_h - f32(rows - 1) * GAP) / f32(rows) - 30,
	)
	tile = max(tile, 100)
	grid_h := f32(rows) * (tile + 30) + f32(rows - 1) * GAP

	ui.inset(gtx, ui.pad_all(MARGIN))
	ui.column(gtx, gap = 16)

	if narrow {
		ui.column(gtx, gap = 8)
		{
			ui.row(gtx, gap = 16, align = .Center)
			draw_toolbar_main(gtx, m)
		}
		{
			ui.row(gtx, gap = 16, align = .Center)
			draw_toolbar_accent(gtx, m)
		}
	} else {
		ui.row(gtx, gap = 20, align = .Center)
		draw_toolbar_main(gtx, m)
		draw_toolbar_accent(gtx, m)
	}
	{
		ui.row(gtx, gap = 24)
		{
			ui.column(gtx, gap = GAP)
			for r in 0 ..< rows {
				ui.row(gtx, gap = GAP, key = u64(r + 1))
				for c in 0 ..< COLS {
					i := r * COLS + c
					if i < len(marks_of(m)) {
						draw_tile(gtx, m, i, k, tile)
					}
				}
			}
		}
		draw_detail(gtx, m, k, detail_w, grid_h)
	}
	ui.persist_struct(gtx, m.state)
}

// lab_fonts is the default face at Primer's three weights, then the first
// bold monospace face found, or the default face when none is.
lab_fonts :: proc() -> []ops.Font_Ref {
	path := ui.default_font()
	out := make([]ops.Font_Ref, 4)
	for w, i in ([3]f32{400, 500, 600}) {
		out[i] = {
			id     = ops.Font_Id(i),
			path   = path,
			weight = w,
		}
	}
	mono := path
	for f in MONO_FILES {
		if os.exists(f) {
			mono = f
			break
		}
	}
	out[3] = {
		id     = FONT_MONO,
		path   = mono,
		weight = 700,
	}
	return out
}

main :: proc() {
	m := Model {
		size     = 2,
		selected = 2,
	}
	fonts := lab_fonts()
	defer delete(fonts)

	if len(os.args) == 1 {
		child.run({ui = draw_lab, user = &m, fonts = fonts})
		return
	}

	size := ops.Size{WIDTH, HEIGHT}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-size":
			if i + 1 >= len(args) {
				fmt.eprintln("-size needs WxH")
				os.exit(2)
			}
			i += 1
			w, _, h := strings.partition(args[i], "x")
			wi, wok := strconv.parse_int(w)
			hi, hok := strconv.parse_int(h)
			if !wok || !hok || wi <= 0 || hi <= 0 {
				fmt.eprintfln("-size wants WxH, got %s", args[i])
				os.exit(2)
			}
			size = {f32(wi), f32(hi)}
		case "-dark":
			m.dark = true
		case "-estoile":
			m.set = 1
		case "-dump":
			p: ui.Probe
			ui.probe_init(&p, draw_lab, &m, size)
			defer ui.probe_destroy(&p)
			fmt.print(ui.probe_dump(&p))
		case "-svg":
			if i + 1 >= len(args) {
				fmt.eprintln("-svg needs a directory")
				os.exit(2)
			}
			i += 1
			if !write_pack(args[i]) {
				os.exit(1)
			}
		case "-png":
			if i + 1 >= len(args) {
				fmt.eprintln("-png needs a path")
				os.exit(2)
			}
			i += 1
			if !render.snapshot(draw_lab, &m, size, fonts, args[i]) {
				fmt.eprintfln("could not write %s", args[i])
				os.exit(1)
			}
		case:
			fmt.eprintfln("unknown flag %s", args[i])
			os.exit(2)
		}
	}
}
