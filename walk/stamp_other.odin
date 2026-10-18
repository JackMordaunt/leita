#+build !linux
#+build !darwin
package walk

// Probing directories is Linux's answer to having no change journal leita reads;
// Windows has the USN journal, so a probe here says every directory changed, and the
// update reads them all, as a walk would.
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	return true
}

// Whether an update asks a copied file its size again: not here. read_windows.odin
// charges a file by rules a path alone cannot repeat (resident streams, compression),
// so a copied file keeps the size it was copied with. The USN journal writes a record
// when a reason first occurs after a file is opened and again when it is closed
// (USN_RECORD_V2, Reason, Microsoft Learn), so this misses a file held open across two
// scans and written before each.
@(private)
RESTATS :: false

// Whether `path` still names the file `id`. Not asked here: a name the base charged
// a file under is believed still there, as the base's own choice would be.
@(private)
still_names :: proc(path: string, id: File_Id) -> bool {
	return true
}
