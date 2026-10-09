/*
Package version says which estoile this is, the one place every binary learns
it: the command line's --version and its reports, and the window's title.
*/
package version

// VERSION is set with -define:ESTOILE_VERSION=x by whatever builds estoile (the
// justfile's version, from git describe); "dev" otherwise.
VERSION :: #config(ESTOILE_VERSION, "dev")
