#+build windows
package leita_app

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf16"

import "../files"

/*
recycled finds what the Recycle Bin holds of dir's entry name: the $I record
saying where it was, and the $R file itself beside it, or "" for both. The Bin
cannot be pointed elsewhere the way XDG_DATA_HOME points the freedesktop.org
Trash, so it is read where it is, at the top of dir's drive, in a folder per
user. A record is matched on the end of the path it holds, dir's last name and
name, since the shell may hold the path long where dir holds it short
(RUNNER~1 for runneradmin).
*/
recycled :: proc(dir, name: string) -> (record, file: string) {
	bin := fmt.tprintf(`%s\$Recycle.Bin`, filepath.volume_name(dir))
	want := fmt.tprintf(`\%s\%s`, filepath.base(dir), name)
	users, err := os.read_all_directory_by_path(bin, context.temp_allocator)
	if err != nil {
		return "", ""
	}
	for user in users {
		// Another user's folder refuses to list, and that is not ours to look in.
		entries, _ := os.read_all_directory_by_path(user.fullpath, context.temp_allocator)
		for e in entries {
			if !strings.has_prefix(e.name, "$I") {
				continue
			}
			was := recorded(e.fullpath)
			if len(was) >= len(want) && strings.equal_fold(was[len(was) - len(want):], want) {
				r := fmt.tprintf(`%s\$R%s`, user.fullpath, e.name[2:])
				return e.fullpath, r
			}
		}
	}
	return "", ""
}

/*
recorded is the path a $I record says its file came from. Since Windows 10 a
record is version 2: the version, the size and when it was deleted, eight bytes
each, then the path's length in UTF-16 units and the path. Version 1 has no
length, and the path fills the rest of a fixed 520 bytes.
*/
@(private = "file")
recorded :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 24 {
		return ""
	}
	version, _ := endian.get_u64(data[0:8], .Little)
	start := 24
	if version == 2 {
		if len(data) < 28 {
			return ""
		}
		start = 28
	}
	units := make([]u16, (len(data) - start) / 2, context.temp_allocator)
	for &u, i in units {
		u, _ = endian.get_u16(data[start + 2 * i:][:2], .Little)
	}
	for u, i in units {
		if u == 0 {
			units = units[:i]
			break
		}
	}
	out := make([]byte, 4 * len(units), context.temp_allocator)
	n := utf16.decode_to_utf8(out, units)
	return string(out[:n])
}

recycle_a_file :: proc(path: string) -> bool {
	return files.trash(path) == .None
}
