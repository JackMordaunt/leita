package update

import "core:fmt"
import "core:os"
import "jm:selfupdate"

// Commit_Status is why the verified file did not become the executable.
// Ok is the only status that changed the launch path. Every other status
// leaves the previous executable where it was.
Commit_Status :: enum {
	Ok,
	Backup,
	Permission,
	Hold,
	Replace,
	Unsupported,
}

// commit_verified puts fresh in exe's place. The previous bytes are kept as
// exe.old first, by a hard link when the volume allows it and otherwise by
// a file that is synced before it is renamed onto .old. The new file receives
// the old mode or ACL before that rename. The launch path is not removed
// first: the platform rename replaces it.
commit_verified :: proc(exe, fresh: string) -> (status: Commit_Status, note: string) {
	old_buf, part_buf: [selfupdate.PATH_CAP]byte
	old := fmt.bprintf(old_buf[:], "%s.old", exe)
	part := fmt.bprintf(part_buf[:], "%s%s", exe, PART_SUFFIX)
	defer os.remove(part)
	if !backup_target(exe, old, part) {
		return .Backup, ""
	}
	if kept, why := preserve_permissions(exe, fresh); !kept {
		return .Permission, why
	}
	if !hold_for_commit() {
		return .Hold, ""
	}
	ok, unsupported, detail := replace_atomically(fresh, exe)
	if unsupported {
		return .Unsupported, detail
	}
	if !ok {
		return .Replace, detail
	}
	return .Ok, ""
}

// hold_for_commit blocks on the lifecycle gate once the backup is durable.
// Unset, which is how a release runs, it does nothing.
@(private)
hold_for_commit :: proc(allocator := context.temp_allocator) -> bool {
	gate := os.get_env(HOLD_COMMIT_ENV, allocator)
	if gate == "" {
		return true
	}
	ready := strings_concat(gate, ".ready")
	if os.write_entire_file(ready, "1") != nil {
		return false
	}
	return block_on_lock(gate)
}

@(private)
strings_concat :: proc(a, b: string) -> string {
	return fmt.tprintf("%s%s", a, b)
}

@(private)
backup_target :: proc(exe, old, part: string) -> bool {
	// A previous .old may still be open on Windows. Removing it is enough
	// when it works; the copy below covers the case where it does not.
	os.remove(old)
	if os.link(exe, old) == nil && same_size(exe, old) {
		return true
	}
	os.remove(old)
	if !copy_synced(exe, part) || !same_size(exe, part) {
		os.remove(part)
		return false
	}
	if os.rename(part, old) != nil || !same_size(exe, old) {
		os.remove(part)
		return false
	}
	return true
}

@(private)
same_size :: proc(a, b: string, allocator := context.temp_allocator) -> bool {
	fa, ea := os.stat(a, allocator)
	if ea != nil {
		os.file_info_delete(fa, allocator)
		return false
	}
	fb, eb := os.stat(b, allocator)
	same := eb == nil && fa.size == fb.size
	os.file_info_delete(fa, allocator)
	os.file_info_delete(fb, allocator)
	return same
}

@(private)
copy_synced :: proc(from, to: string) -> bool {
	src, err := os.open(from, {.Read})
	if err != nil {
		return false
	}
	defer os.close(src)
	dst, derr := os.open(to, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if derr != nil {
		return false
	}
	defer os.close(dst)
	buf: [32 * 1024]byte
	for {
		n, rerr := os.read(src, buf[:])
		if n > 0 && !write_all(dst, buf[:n]) {
			return false
		}
		if rerr != nil {
			if rerr == .EOF {
				break
			}
			return false
		}
		if n == 0 {
			break
		}
	}
	return sync_file(dst)
}

@(private)
write_all :: proc(f: ^os.File, data: []byte) -> bool {
	buf := data
	for len(buf) > 0 {
		n, err := os.write(f, buf)
		if err != nil || n <= 0 {
			return false
		}
		buf = buf[n:]
	}
	return true
}
