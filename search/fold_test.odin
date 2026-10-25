package search

import "core:testing"

@(private = "file")
finds :: proc(term, text: string) -> bool {
	p := pattern_make(term)
	s := new(Scratch)
	defer free(s)

	_, ok := score(&p, text, s)
	return ok
}

/*
Matching folds case by Unicode's simple mapping and fzf's table of Latin letters,
never by the locale: it calls no libc case function, so a person in tr_TR, ja_JP,
de_DE or the C locale finds the same files with the same term. The capital I is i
everywhere, which a Turkish case mapping would not make it, and the Turkish letters
fold to the Latin ones as the table has them.
*/
@(test)
case_folds_the_same_in_every_locale :: proc(t: ^testing.T) {
	// A term without capitals ignores case (smart case, as fzf has it).
	testing.expect(t, finds("istanbul", "ISTANBUL.TXT"), "I is i")
	testing.expect(t, finds("istanbul", "Istanbul.txt"))
	testing.expect(t, finds("ıstanbul", "ISTANBUL.TXT"), "dotless ı is i")
	// The dotted capital and the dotless small letter fold to the base letter.
	testing.expect(t, finds("istanbul", "İstanbul.txt"), "İ folds to i")
	testing.expect(t, finds("kapi", "kapı.txt"), "ı folds to i")
	testing.expect(t, finds("kapı", "kapi.txt"), "i is ı")
	testing.expect(t, finds("kapı", "KAPI.txt"))
	// A capital in the term asks for case to be kept, here as everywhere.
	testing.expect(t, !finds("ISTANBUL", "istanbul.txt"), "smart case keeps a capital")
	testing.expect(t, finds("ISTANBUL", "ISTANBUL.txt"))
	// German: ß is s as the table has it, and umlauts fold to their base letter.
	testing.expect(t, finds("strase", "straße.txt"))
	testing.expect(t, finds("straße", "STRASE.txt"))
	testing.expect(t, finds("uber", "Über.txt"))
	testing.expect(t, finds("über", "UBER.txt"))
	// Japanese has no case: a name matches itself, and a fullwidth letter is its
	// ASCII one.
	testing.expect(t, finds("日本", "日本語.txt"))
	testing.expect(t, !finds("本日", "日本語.txt"))
	testing.expect(t, finds("full", "ｆｕｌｌ.txt"))
}
