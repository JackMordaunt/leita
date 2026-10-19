/*
Package version says which leita this is, the one place every binary learns
it: the command line's --version and its reports, and the window's title.
*/
package version

// VERSION is set with -define:LEITA_VERSION=x by whatever builds leita (the
// justfile's version, from git describe); "dev" otherwise.
VERSION :: #config(LEITA_VERSION, "dev")

// YEAR is the year of this build, for the copyright line, set with
// -define:LEITA_YEAR=n by whatever builds leita (the justfile's year, from the
// date it is built); 2026 otherwise, the year LICENSE.md carries.
YEAR :: #config(LEITA_YEAR, 2026)

// PRODUCT is the product's name as the window and its messages spell it: the
// toolbar, the window's title, the About dialog, and every message that names
// the product.
PRODUCT :: "Leita"

// NAME is the command's name as typed at a prompt, and as the command line's
// messages spell it. The binaries' file names and the LEITA_ variables are the
// build's and the environment's, and change apart from it.
NAME :: "leita"

// SHORT is the command line's short name, installed beside leita as the same
// binary: set with -define:LEITA_SHORT=x from the justfile's short, so -h
// names what install put on PATH.
SHORT :: #config(LEITA_SHORT, "le")

// RELEASED is this build's authenticated release instant, the canonical UTC
// form YYYY-MM-DDTHH:MM:SSZ, set with -define:LEITA_RELEASED= by the release
// that wrote released.txt. Empty on a development build, which a licence
// line does not entitle.
RELEASED :: #config(LEITA_RELEASED, "")
