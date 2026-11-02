#+build freebsd
package scan

import "core:c"
import "core:mem"
import "core:strings"
import "core:sys/posix"

// Built by tools/freebsd/native.py against this system's <sys/mount.h>. C owns
// struct statfs, so a different FreeBSD layout cannot overwrite an Odin struct.
foreign import freebsd_mount "lib/freebsd.a"

@(private = "file", default_calling_convention = "c")
foreign freebsd_mount {
	leita_freebsd_mount_id   :: proc(fd: c.int, out: ^[2]i32) -> c.int ---
	leita_freebsd_mount_path :: proc(path: cstring, point: [^]u8, point_capacity: c.size_t, source: [^]u8, source_capacity: c.size_t, kind: [^]u8, kind_capacity: c.size_t) -> c.int ---
	leita_freebsd_mounts     :: proc(out: [^]u8, capacity: c.size_t, needed: ^c.size_t) -> c.int ---
}

// The opened mount's identity, also distinct for a nullfs alias whose files have
// the same st_dev and st_ino as the underlying filesystem. No allocation.
mount_id_freebsd :: proc(fd: posix.FD) -> (id: [2]i32, ok: bool) {
	ok = leita_freebsd_mount_id(c.int(fd), &id) == 0
	// A restricted jail can hide every fsid as zero. Those mounts cannot be
	// distinguished, so refusing the identity is safer than crossing aliases.
	ok = ok && id != [2]i32{}
	return
}

@(private)
mounted_at_freebsd :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	device, mount: string,
	fs: Filesystem,
	found: bool,
) {
	point, source: [4096]u8
	kind: [256]u8
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if leita_freebsd_mount_path(
		   cpath,
		   raw_data(point[:]),
		   len(point),
		   raw_data(source[:]),
		   len(source),
		   raw_data(kind[:]),
		   len(kind),
	   ) !=
	   0 {
		return "", "", .Unknown, false
	}
	point_text := string(cstring(&point[0]))
	if point_text == "" || point_text[0] != '/' || !covers(point_text, path) {
		return "", "", .Unknown, false
	}
	device_err: mem.Allocator_Error
	device, device_err = strings.clone(string(cstring(&source[0])), allocator)
	if device_err != nil {
		return "", "", .Unknown, false
	}
	mount_err: mem.Allocator_Error
	mount, mount_err = strings.clone(point_text, allocator)
	if mount_err != nil {
		delete(device, allocator)
		return "", "", .Unknown, false
	}
	return device, mount, filesystem_from_name(string(cstring(&kind[0]))), true
}

// Owned absolute mount paths, including nullfs aliases. Failure is explicit;
// callers must not treat a failed enumeration as proof there are no mounts.
mounts_freebsd :: proc(allocator := context.allocator) -> (points: []string, ok: bool) {
	needed: c.size_t
	if leita_freebsd_mounts(nil, 0, &needed) != 0 || needed > c.size_t(max(int)) {
		return nil, false
	}
	buffer, buffer_err := make([]u8, int(needed), context.temp_allocator)
	if buffer_err != nil {
		return nil, false
	}
	if leita_freebsd_mounts(raw_data(buffer), len(buffer), &needed) != 0 ||
	   needed > c.size_t(len(buffer)) {
		return nil, false
	}
	out := make([dynamic]string, allocator)
	defer if !ok {
		for point in out {delete(point, allocator)}
		delete(out)
	}
	start := 0
	for at in 0 ..< int(needed) {
		if buffer[at] != 0 {
			continue
		}
		point, clone_err := strings.clone(string(buffer[start:at]), allocator)
		if clone_err != nil {
			return nil, false
		}
		if _, append_err := append(&out, point); append_err != nil {
			delete(point, allocator)
			return nil, false
		}
		start = at + 1
	}
	return out[:], true
}
