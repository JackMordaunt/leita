package leita_history
import "../schema"
import "core:strings"
import "jm:sqlite3"

// A fallback reads an existing compatible store. It never creates missing
// tables, stamps a version or alters persistent data.
@(private)
open_read_only :: proc(st: ^Store, path: string, original: sqlite3.Error) -> sqlite3.Error {
	db := schema.read_only(path, BUSY_WAIT) or_return
	ok := false
	defer if !ok {sqlite3.close(&db)}
	version := schema.user_version(db, db.allocator) or_return
	if version > SCHEMA_VERSION {return newer_schema(version)}
	schema.require_select(
		db,
		"SELECT id, top, taken, bytes, items FROM snapshot LIMIT 0",
	) or_return
	schema.require_select(db, "SELECT snapshot, path, bytes FROM entry LIMIT 0") or_return
	if version > 0 {
		schema.require_select(db, "SELECT disk_total,disk_free FROM snapshot LIMIT 0") or_return
		schema.require_select(
			db,
			"SELECT taken,kind,path,detail,bytes,failed FROM action LIMIT 0",
		) or_return
	}
	st.db = db
	st.read_only = true
	st.read_only_reason = schema.read_only_reason(path, original)
	st.legacy = version == 0
	ok = true
	return nil
}

@(private)
write_allowed :: proc(st: ^Store) -> sqlite3.Error {
	if st.read_only {return sqlite3.Fault{code = .Read_Only, text = strings.clone(st.read_only_reason, st.db.allocator)}}
	return nil
}
