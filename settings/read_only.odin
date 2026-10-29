package leita_settings
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
	schema.require_select(db, "SELECT key, value FROM setting LIMIT 0") or_return
	if version > 0 {
		for sql in ([]string{"SELECT place,every,added,warn_used,fail_used,min_free,full_within,growth FROM watch LIMIT 0", "SELECT id,place,started,seconds,bytes,disk_total,disk_free,updated,reread,taken,why,problem,firing FROM run LIMIT 0", "SELECT id,place,raised,kind,used_percent,free,total,days,grew,limit_crossed,problem FROM raised LIMIT 0", "SELECT id,url,secret,paths,added,last_sent,last_problem FROM webhook LIMIT 0", "SELECT id,hook,event,body,created,attempts,next_at,problem FROM delivery LIMIT 0"}) {schema.require_select(db, sql) or_return}
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
