package main

import "core:fmt"
import "core:strings"
import "core:testing"

import mark "../../gui/mark"

// Each scheme's mark and hero carry the scheme's ink and the wordmark, and
// the hero's mark is the same as the mark file's.
@(test)
pack_carries_the_ink_and_the_wordmark :: proc(t: ^testing.T) {
	for k in ([2]Ink{LIGHT, DARK}) {
		ink := fmt.tprintf(`fill="%s"`, mark.hex(k.ink))
		m, h := mark_svg(k), hero_svg(k)
		testing.expect(t, strings.contains(m, ink), "mark lacks the scheme's ink")
		testing.expect(t, strings.contains(h, ">estoile</text>"), "wordmark missing")
		testing.expect_value(t, strings.count(h, "<path "), strings.count(m, "<path "))
	}
}
