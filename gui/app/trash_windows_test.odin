#+build windows
package leita_app

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf16"

import "../../home"
import "../files"

/*
recycled finds what this account's Recycle Bin holds of dir's entry name: the
$I record saying where it was, and the $R file beside it, or "" for both. The
folder is `<volume>\$Recycle.Bin\<sid>` for this process's token, the same
folder Reclaim sizes. Other SID folders are excluded. A record is
matched on the end of the path it holds, dir's last name and name, since the
shell may hold the path long where dir holds it short (RUNNER~1 for
runneradmin).
*/
recycled :: proc(dir, name: string) -> (record, file: string) {
	who := home.user(context.temp_allocator)
	defer home.user_destroy(&who, context.temp_allocator)
	if who.uid == "" {
		return "", ""
	}
	folder := fmt.tprintf(`%s\$Recycle.Bin\%s`, filepath.volume_name(dir), who.uid)
	return recycled_in(folder, fmt.tprintf(`\%s\%s`, filepath.base(dir), name))
}

// recycled_in is the $I and $R in folder whose record ends with want.
@(private = "file")
recycled_in :: proc(folder, want: string) -> (record, file: string) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		return "", ""
	}
	for e in entries {
		if !strings.has_prefix(e.name, "$I") {
			continue
		}
		was := recorded(e.fullpath)
		if len(was) >= len(want) && strings.equal_fold(was[len(was) - len(want):], want) {
			return e.fullpath, fmt.tprintf(`%s\$R%s`, folder, e.name[2:])
		}
	}
	return "", ""
}

/*
recycled_elsewhere is a $I/$R pair for dir's name in some other listable
folder under that volume's $Recycle.Bin. A failure of recycled names it, so
the next run shows where the shell put the file. "" when no other folder has
it. The pair is the caller's to delete.
*/
recycled_elsewhere :: proc(dir, name: string) -> (record, file: string) {
	who := home.user(context.temp_allocator)
	defer home.user_destroy(&who, context.temp_allocator)
	bin := fmt.tprintf(`%s\$Recycle.Bin`, filepath.volume_name(dir))
	want := fmt.tprintf(`\%s\%s`, filepath.base(dir), name)
	users, err := os.read_all_directory_by_path(bin, context.temp_allocator)
	if err != nil {
		return "", ""
	}
	for user in users {
		if who.uid != "" && strings.equal_fold(user.name, who.uid) {
			continue
		}
		record, file = recycled_in(user.fullpath, want)
		if file != "" {
			return
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
