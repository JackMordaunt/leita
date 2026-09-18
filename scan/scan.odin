/*
Package scan holds the seam between the readers that find files and the tree the UI
reads.

A reader knows how to discover files on one kind of filesystem. It does not get to
decide how they are recorded, because everything above this line has to work the same
whichever reader ran. So the shared parts live here: resolving what the user asked
for, choosing a reader for it, and the tree they all write into.

Dispatch is a switch at the one place a reader is chosen, not an interface. The set
of readers is known when the program is built, so nothing is gained by describing it
to the compiler at runtime.
*/
package scan

Error :: enum {
	None,
	Target_Not_Found,
	Out_Of_Memory,
	Unsupported_Platform,
}
