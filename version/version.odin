/*
Package version says which leita this is, the one place every binary learns
it: the command line's --version and its reports, and the window's title.
*/
package version

// VERSION is set with -define:LEITA_VERSION=x by whatever builds leita (the
// justfile's version, from git describe); "dev" otherwise.
VERSION :: #config(LEITA_VERSION, "dev")
