package pdf

import "core:os"

// System fonts: neither this package nor its users ship a font, so text is set
// in what the machine has. Each list is tried in order, the first that loads
// taken; the first list's font is the one text is drawn in, and the rest are
// its fallbacks, for the scripts it lacks. Whether a font may be embedded is
// read from its OS/2 fsType (OpenType spec, OS/2 table; the bits face_init
// checks): add_font refuses one that forbids it, whatever its source.

@(private)
SYSTEM_FONTS :: [][]string {
	// The font text is drawn in: a sans-serif.
	{
		"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
		"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
		"/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
		"/usr/share/fonts/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"C:/Windows/Fonts/arial.ttf",
		"C:/Windows/Fonts/segoeui.ttf",
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/Library/Fonts/Arial.ttf",
	},
	// A CJK font.
	{
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/noto-cjk/NotoSansCJKjp-Regular.otf",
		"/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
		"/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
		"C:/Windows/Fonts/msgothic.ttc",
		"C:/Windows/Fonts/msyh.ttc",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
		"/Library/Fonts/Arial Unicode.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansArabic-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansHebrew-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansDevanagari-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansThai-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf",
	},
	{"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf", "C:/Windows/Fonts/seguisym.ttf"},
}

// add_system_fonts adds a sans-serif font found on this machine and, as its
// fallbacks, whichever fonts for other scripts are there too, and returns the
// first. false when no sans-serif font of SYSTEM_FONTS is installed. Fonts
// are read whole and kept until destroy: NotoSansCJK-Regular.ttc is
// 19,484,784 bytes on Arch (noto-fonts-cjk, 2025-02).
//
// Given bold, it also adds the bold face of the sans-serif chosen, with the
// same fallbacks, and sets bold to it; to the regular face where SYSTEM_BOLD
// names none beside it, or that one is not installed.
add_system_fonts :: proc(doc: ^Document, bold: ^Font = nil) -> (Font, bool) {
	primary, heavy := Font(-1), Font(-1)
	for paths in SYSTEM_FONTS {
		for path, i in paths {
			if !os.exists(path) {
				continue
			}
			font, err := add_font_file(doc, path)
			if err != .None {
				continue
			}
			if primary < 0 {
				primary = font
				if bolds := SYSTEM_BOLD; bold != nil && i < len(bolds) && os.exists(bolds[i]) {
					if b, berr := add_font_file(doc, bolds[i]); berr == .None {
						heavy = b
					}
				}
			} else {
				add_fallback(doc, primary, font)
				if heavy >= 0 {
					add_fallback(doc, heavy, font)
				}
			}
			break
		}
		if primary < 0 {
			return -1, false
		}
	}
	if bold != nil {
		bold^ = heavy if heavy >= 0 else primary
	}
	return primary, true
}

// SYSTEM_BOLD is the bold face of each sans-serif in SYSTEM_FONTS' first list,
// at the same index.
@(private)
SYSTEM_BOLD :: []string {
	"/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf",
	"/usr/share/fonts/TTF/LiberationSans-Bold.ttf",
	"/usr/share/fonts/noto/NotoSans-Bold.ttf",
	"/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
	"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	"C:/Windows/Fonts/arialbd.ttf",
	"C:/Windows/Fonts/segoeuib.ttf",
	"/System/Library/Fonts/Supplemental/Arial Bold.ttf",
	"/Library/Fonts/Arial Bold.ttf",
}
