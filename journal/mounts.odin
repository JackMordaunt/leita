package journal

import "core:strconv"
import "core:strings"

/*
One line of /proc/self/mountinfo (proc_pid_mountinfo(5)): the mount's id, the
device as major:minor, the folder of the filesystem mounted (root), where it is
mounted (point), its type, and the filesystem's own options (super). judge reads
those and not the mount's: a mount made read-only over a writable filesystem, as
ProtectSystem=strict in the service makes them (systemd.exec(5)), is still
recorded. Shown on Linux 7.0.14 by remounting / and /mnt/e read-only in a mount
namespace of the recorder's own (2026-10-13).
*/
Mount :: struct {
	id:     int,
	device: string,
	root:   string,
	point:  string,
	fstype: string,
	super:  string,
}

/*
mounts_parse reads the text of /proc/self/mountinfo, its strings in allocator with
the kernel's octal escapes (\040 for a space) undone. A line it cannot read is left
out.
*/
mounts_parse :: proc(text: string, allocator := context.allocator) -> []Mount {
	out := make([dynamic]Mount, allocator)
	text := text
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		dash := -1
		for f, i in fields {
			if f == "-" {
				dash = i
				break
			}
		}
		if len(fields) < 6 || dash < 6 || dash + 3 >= len(fields) {
			continue
		}
		id, id_ok := strconv.parse_int(fields[0], 10)
		if !id_ok {
			continue
		}
		append(
			&out,
			Mount {
				id = id,
				device = strings.clone(fields[2], allocator),
				root = unescape(fields[3], allocator),
				point = unescape(fields[4], allocator),
				fstype = strings.clone(fields[dash + 1], allocator),
				super = strings.clone(fields[dash + 3], allocator),
			},
		)
	}
	return out[:]
}

mounts_destroy :: proc(mounts: []Mount, allocator := context.allocator) {
	for m in mounts {
		delete(m.device, allocator)
		delete(m.root, allocator)
		delete(m.point, allocator)
		delete(m.fstype, allocator)
		delete(m.super, allocator)
	}
	delete(mounts, allocator)
}

// unescape undoes mountinfo's three-digit octal escapes, in allocator.
@(private)
unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) && is_octal(s[i + 1:i + 4]) {
			strings.write_byte(
				&b,
				(s[i + 1] - '0') << 6 | (s[i + 2] - '0') << 3 | (s[i + 3] - '0'),
			)
			i += 3
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private)
is_octal :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if c < '0' || c > '7' {
			return false
		}
	}
	return true
}

// Filesystems with no disk behind them, or whose contents are made up or never
// change: never recorded, and not listed as skipped.
@(private, rodata)
PSEUDO := [?]string {
	"autofs",
	"binfmt_misc",
	"bpf",
	"cgroup",
	"cgroup2",
	"configfs",
	"debugfs",
	"devpts",
	"devtmpfs",
	"efivarfs",
	"erofs",
	"fusectl",
	"hugetlbfs",
	"iso9660",
	"mqueue",
	"nsfs",
	"overlay",
	"proc",
	"pstore",
	"ramfs",
	"rpc_pipefs",
	"securityfs",
	"selinuxfs",
	"squashfs",
	"sysfs",
	"tmpfs",
	"tracefs",
}

// Filesystems another machine can change, which no mark here would see.
@(private, rodata)
NETWORK := [?]string {
	"9p",
	"ceph",
	"cifs",
	"fuse.sshfs",
	"glusterfs",
	"nfs",
	"nfs4",
	"smb3",
	"smbfs",
	"virtiofs",
}

/*
judge is whether the recorder should try to mark m's filesystem: every local one
that can change, less FUSE filesystems whose mount point is not in `only`. When it
should not, why says so for the status, or is "" for a filesystem not worth listing
(proc, tmpfs and the like).

A FUSE filesystem answers through a program, often one a user runs, that can stop
answering: the recorder, opening its mount point to resolve what changed, would
wait on it, and record no other filesystem while it waited.
*/
judge :: proc(m: Mount, only: []string = nil) -> (try: bool, why: string) {
	for t in PSEUDO {
		if m.fstype == t {
			return false, ""
		}
	}
	for t in NETWORK {
		if m.fstype == t {
			return false, "a network filesystem, which another machine can change"
		}
	}
	fuse := m.fstype == "fuse" || m.fstype == "fuseblk" || strings.has_prefix(m.fstype, "fuse.")
	if fuse && !listed(only, m.point) {
		return false, "a FUSE filesystem, whose program could keep the recorder waiting"
	}
	options := m.super
	for o in strings.split_iterator(&options, ",") {
		if o == "ro" {
			return false, "the filesystem is read-only"
		}
	}
	return true, ""
}

/*
The recorder's verdicts on the mount table: each mount tried, by id, with its
device and the filesystem's options then; each device recorded or skipped; and why
each skipped one was. A device is judged again once no mount of it is left, or once
its options change, so a disk plugged in again, or a filesystem remounted read-write,
is tried again and the status lists no filesystem that has gone.
*/
@(private)
Verdicts :: struct {
	mounts:  map[int]Tried_Mount,
	devices: map[string]struct{},
	skipped: [dynamic]Skipped_Filesystem,
}

@(private)
Tried_Mount :: struct {
	device: string,
	super:  string,
}

// A filesystem the recorder does not record, and why.
@(private)
Skipped_Filesystem :: struct {
	device: string,
	point:  string,
	fstype: string,
	why:    string,
}

// verdicts_try is whether m is new to j, by its id; it is noted as tried either way.
@(private)
verdicts_try :: proc(j: ^Verdicts, m: Mount) -> bool {
	if m.id in j.mounts {
		return false
	}
	j.mounts[m.id] = {strings.clone(m.device), strings.clone(m.super)}
	return true
}

// verdicts_record notes m's device as recorded.
@(private)
verdicts_record :: proc(j: ^Verdicts, m: Mount) {
	if m.device not_in j.devices {
		j.devices[strings.clone(m.device)] = {}
	}
}

// verdicts_skip notes m's device as skipped, and why, unless it was judged already.
@(private)
verdicts_skip :: proc(j: ^Verdicts, m: Mount, why: string) {
	if m.device in j.devices {
		return
	}
	j.devices[strings.clone(m.device)] = {}
	append(
		&j.skipped,
		Skipped_Filesystem {
			device = strings.clone(m.device),
			point = strings.clone(m.point),
			fstype = strings.clone(m.fstype),
			why = strings.clone(why),
		},
	)
}

/*
verdicts_prune brings j up to date with mounts, the table as it is now. A mount
gone is forgotten, since its id may be given to a later mount (proc_pid_mountinfo(5)).
A device with no mount left, or whose options changed, is forgotten with every mount
of it and its status line, unless it is one of recorded: the caller stops a
recording whose mount went, and forgets its device, before it prunes.
*/
@(private)
verdicts_prune :: proc(j: ^Verdicts, mounts: []Mount, recorded: []string) {
	gone := make([dynamic]int, context.temp_allocator)
	stale := make([dynamic]string, context.temp_allocator)
	for id, was in j.mounts {
		now, here := mount_by_id(mounts, id)
		if !here {
			append(&gone, id)
		}
		changed := here && now.super != was.super
		if changed || !here && !device_mounted(mounts, was.device) {
			append(&stale, strings.clone(was.device, context.temp_allocator))
		}
	}
	for id in gone {
		verdicts_drop_mount(j, id)
	}
	for device in stale {
		if !listed(recorded, device) {
			verdicts_forget(j, device)
		}
	}
}

// verdicts_forget forgets device: every mount of it is tried again.
@(private)
verdicts_forget :: proc(j: ^Verdicts, device: string) {
	if device in j.devices {
		key, _ := delete_key(&j.devices, device)
		delete(key)
	}
	ids := make([dynamic]int, context.temp_allocator)
	for id, m in j.mounts {
		if m.device == device {
			append(&ids, id)
		}
	}
	for id in ids {
		verdicts_drop_mount(j, id)
	}
	for i := len(j.skipped) - 1; i >= 0; i -= 1 {
		if j.skipped[i].device == device {
			skipped_filesystem_destroy(j.skipped[i])
			ordered_remove(&j.skipped, i)
		}
	}
}

@(private)
verdicts_drop_mount :: proc(j: ^Verdicts, id: int) {
	if id in j.mounts {
		_, m := delete_key(&j.mounts, id)
		delete(m.device)
		delete(m.super)
	}
}

@(private)
verdicts_destroy :: proc(j: ^Verdicts) {
	for _, m in j.mounts {
		delete(m.device)
		delete(m.super)
	}
	delete(j.mounts)
	for k in j.devices {
		delete(k)
	}
	delete(j.devices)
	for s in j.skipped {
		skipped_filesystem_destroy(s)
	}
	delete(j.skipped)
}

@(private)
skipped_filesystem_destroy :: proc(s: Skipped_Filesystem) {
	delete(s.device)
	delete(s.point)
	delete(s.fstype)
	delete(s.why)
}

@(private)
mount_by_id :: proc(mounts: []Mount, id: int) -> (Mount, bool) {
	for m in mounts {
		if m.id == id {
			return m, true
		}
	}
	return {}, false
}

@(private)
device_mounted :: proc(mounts: []Mount, device: string) -> bool {
	for m in mounts {
		if m.device == device {
			return true
		}
	}
	return false
}

@(private)
listed :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}
