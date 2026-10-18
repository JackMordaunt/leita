/*
Package notices is the licence of everything the window is built from that
leita's own licence does not cover: each component it links or carries, and
the notice that component's licence asks to travel with it. The texts are
copied into text/ and embedded in the binary by #load, so the window shows
them with nothing else installed.

The list follows jm's THIRD_PARTY.md, narrowed to what the window imports:
jm itself, Odin's core and SDL3, Blend2D and asmjit to draw, the odin-blend2d
binding, kb_text_shape to shape text, AccessKit for screen readers, SQLite for
the history, libcurl for the one licence request, Primer's tokens, behaviours
and Octicons, and the Liberation Sans pdf carries for reports. Windows builds link the libcurl.lib Odin bundles,
which carries mbedTLS and zlib (jm/http/http.odin, THIRD_PARTY.md), and list
them too.

Where each text came from: jm/LICENSE; odin root's LICENSE and
vendor/sdl3/LICENSE.txt; jm's `just blend2d` checkouts' LICENSE.md;
jm/ui/blend2d/LICENSE; jm/ui/kb/vendor/LICENSE; the accesskit-c 0.23.1 release
archive's LICENSE-MIT and LICENSE.chromium; curl's COPYING; pdf/fonts/LICENSE,
from the liberation-fonts-ttf-2.1.5 release; the LICENSE of
each package under jm/tools/primer/upstream/npm; madler/zlib's and
Mbed-TLS/mbedtls's LICENSE. To add a component, copy its notice into text/ and
add it here. THIRD_PARTY.md at the repository root is rendered from ALL and
WINDOWS; the test in this package fails when the committed file differs.

The version field is the release this tree records for the component, empty
when it records none. AccessKit 0.23.1 is the accesskit-c archive named above.
SQLite 3.53.4 is the vendored header. SDL 3.4.2 is the sdl3-tag the setup
action binds. The Primer packages are the versions in each package.json under
jm/tools/primer/upstream/npm.
*/
package leita_notices

// Notice is one component: its name, the release where this tree records one,
// the licence it is under, where it lives, and the notice its licence asks to
// be shown.
Notice :: struct {
	name:    string,
	version: string, // empty when this tree records no release
	licence: string, // an SPDX expression, or a plain phrase where there is none
	url:     string,
	text:    string,
}

// ALL is every component's notice, in the order the window lists them.
ALL := [?]Notice {
	{
		"AccessKit",
		"0.23.1",
		"MIT OR Apache-2.0",
		"https://accesskit.dev",
		#load("text/accesskit.txt", string),
	},
	{
		"AccessKit, from Chromium",
		"0.23.1",
		"BSD-3-Clause",
		"https://accesskit.dev",
		#load("text/accesskit-chromium.txt", string),
	},
	{"asmjit", "", "Zlib", "https://asmjit.com", #load("text/asmjit.txt", string)},
	{"Blend2D", "", "Zlib", "https://blend2d.com", #load("text/blend2d.txt", string)},
	{"curl", "", "curl", "https://curl.se", #load("text/curl.txt", string)},
	{"jm", "", "Apache-2.0", "https://mordaunt.dev/code/jm", #load("text/jm.txt", string)},
	{
		"kb_text_shape",
		"",
		"Zlib",
		"https://github.com/JimmyLefevre/kb",
		#load("text/kb_text_shape.txt", string),
	},
	{
		"Liberation Sans",
		"2.1.5",
		"OFL-1.1",
		"https://github.com/liberationfonts/liberation-fonts",
		#load("text/liberation.txt", string),
	},
	{"Odin", "", "Zlib", "https://odin-lang.org", #load("text/odin.txt", string)},
	{
		"odin-blend2d",
		"",
		"Unlicense OR MIT",
		"https://mordaunt.dev/code/jm",
		#load("text/odin-blend2d.txt", string),
	},
	{
		"Octicons",
		"19.38.0",
		"MIT",
		"https://github.com/primer/octicons",
		#load("text/primer-octicons.txt", string),
	},
	{
		"Primer behaviors",
		"1.10.3",
		"MIT",
		"https://github.com/primer/behaviors",
		#load("text/primer-behaviors.txt", string),
	},
	{
		"Primer primitives",
		"11.10.0",
		"MIT",
		"https://github.com/primer/primitives",
		#load("text/primer-primitives.txt", string),
	},
	{
		"relative-time-element",
		"5.0.0",
		"MIT",
		"https://github.com/github/relative-time-element",
		#load("text/primer-relative-time-element.txt", string),
	},
	{"SDL", "3.4.2", "Zlib", "https://libsdl.org", #load("text/sdl3.txt", string)},
	// SQLite's dedication asks for no notice; it is said so the list names
	// everything the window links.
	{
		"SQLite",
		"3.53.4",
		"Public domain",
		"https://sqlite.org",
		`The author disclaims copyright to this source code. In place of a legal notice, here is a blessing:

    May you do good and not evil.
    May you find forgiveness for yourself and forgive others.
    May you share freely, never taking more than you give.

SQLite is in the public domain: https://sqlite.org/copyright.html`,
	},
}

// WINDOWS is what the libcurl.lib Odin bundles carries, linked on Windows in
// place of a system curl (jm/http/http.odin). It is compiled on every OS so
// THIRD_PARTY.md, rendered from this package, names them on the machine that
// writes the file. The About shows the list only where the build links it.
WINDOWS := [?]Notice {
	{
		"Mbed TLS",
		"",
		"Apache-2.0 OR GPL-2.0-or-later",
		"https://www.trustedfirmware.org/projects/mbed-tls",
		#load("text/mbedtls.txt", string),
	},
	{"zlib", "", "Zlib", "https://zlib.net", #load("text/zlib.txt", string)},
}
