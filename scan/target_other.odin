#+build !windows
package scan

import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"

import "../kstat"

/*
Resolve what was given into a target backends can dispatch on.

Three shapes arrive here. A block device names a volume, a regular file is taken to
hold an image of one, and both are identified by the signature at the front of them.
A directory names a place inside a volume, which the mount table accounts for.

Reading a signature is not parsing a filesystem: saying which reader applies is this
layer's job, and doing it here keeps that job free of every backend, exactly as
asking Windows for a volume's filesystem name does.

The reader comes back with the target. Choosing one needs to know whether the volume
opens, which is found out here, so leaving the caller to ask separately would only
mean opening it twice.

made_up, a day, resolves to the made-up disk of that day in place of input: the
caller passes what synthetic_day read at its startup, nothing to scan what is real.
*/
resolve :: proc(
	input: string,
	allocator := context.allocator,
	made_up: Maybe(int) = nil,
) -> (
	t: Target,
	c: Choice,
	err: Error,
) {
	if made, choice, ok := synthetic(input, made_up, allocator); ok {
		return made, choice, .None
	}
	info, stat_err := kstat.stat(input, context.temp_allocator)
	if stat_err != nil {
		if stat_err == io.Error.Permission_Denied {
			return {}, {}, .Access_Denied
		}
		return {}, {}, .Target_Not_Found
	}

	t.allocator = allocator
	t.input = strings.clone(input, allocator)

	path := info.fullpath

	#partial switch info.type {
	case .Block_Device, .Regular:
		t.image = info.type == .Regular
		t.volume = strings.clone(path, allocator)
		fs, sig_err := signature(path)
		if sig_err != .None {
			target_destroy(&t)
			return {}, {}, sig_err
		}
		t.fs = fs
		if !t.image {
			t.media = media_of(path)
		}
		// Reading the signature opened it, so there is nothing left to find out.
		return t, choose(t, true), .None

	case .Directory:
		device, mount, fs, found := mounted_at(path, allocator)
		if !found {
			target_destroy(&t)
			return {}, {}, .Unsupported_Platform
		}
		t.volume = device
		t.mount = mount
		t.fs = fs
		// A share's source names a server, not a device anything here could ask about.
		if fs != .Network {
			t.media = media_of(device)
		}
		// Whatever lies below the mount point is the subtree to report on. Kept so
		// that the mount point and this concatenate back into the path.
		if len(path) > len(mount) {
			t.root = strings.clone(path[len(mount):], allocator)
		}
		// Reached through its mount point, so nothing so far has touched the device.
		// Whether that opens is what decides between reading the filesystem whole and
		// walking what is mounted from it.
		return t, choose(t, can_open(device)), .None
	}

	target_destroy(&t)
	return {}, {}, .Target_Not_Found
}

// Whether a volume opens for raw reading. Unix keeps that answer in the device's
// permissions and the groups held rather than in the process, so opening it is the
// only test that covers every reason it might be refused.
@(private)
can_open :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	f, err := os.open(path, {.Read})
	if err != nil {
		return false
	}
	os.close(f)
	return true
}

/*
The filesystem whose signature sits at the front of a volume.

Every one of these writes its name into the boot sector, at one of two offsets: the
OEM field for the NTFS family, and the type field further in for FAT. Reading 512
bytes is enough to tell them apart, and enough to say that none of them match.
*/
@(private)
signature :: proc(path: string) -> (Filesystem, Error) {
	f, open_err := os.open(path, {.Read})
	if open_err != nil {
		if open_err == io.Error.Permission_Denied {
			return .Unknown, .Access_Denied
		}
		return .Unknown, .Target_Not_Found
	}
	defer os.close(f)

	boot: [512]byte
	n, read_err := os.read_at(f, boot[:], 0)
	if read_err != nil || n < len(boot) {
		// Too small to hold a boot sector, so nothing here names a filesystem.
		return .Unknown, .None
	}

	oem := string(boot[3:11])
	switch {
	case oem == "NTFS    ":
		return .Ntfs, .None
	case oem == "EXFAT   ":
		return .Exfat, .None
	case strings.has_prefix(oem, "ReFS"):
		return .Refs, .None
	}
	if string(boot[82:90]) == "FAT32   " {
		return .Fat32, .None
	}
	if strings.has_prefix(string(boot[54:62]), "FAT") {
		return .Fat32, .None
	}
	return .Unknown, .None
}

/*
The mount covering `path`: the device behind it, where it is mounted, and what runs
there.

The longest mount point that prefixes the path wins, which is what makes a filesystem
mounted inside another resolve to the inner one. Names are returned owned.
*/
@(private)
mounted_at :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	device, mount: string,
	fs: Filesystem,
	found: bool,
) {
	when ODIN_OS == .Darwin {
		return mounted_at_statfs(path, allocator)
	} else when ODIN_OS != .Linux {
		// Other unixes report their mounts through getmntinfo rather than a file.
		return "", "", .Unknown, false
	} else {
		table, read_err := os.read_entire_file_from_path(PROC_MOUNTS, context.temp_allocator)
		if read_err != nil {
			return "", "", .Unknown, false
		}

		best_device, best_mount, best_type: string
		text := string(table)

		for line in strings.split_lines_iterator(&text) {
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) < 3 {
				continue
			}
			point := unescape(fields[1], context.temp_allocator)
			if !covers(point, path) || len(point) < len(best_mount) {
				continue
			}
			best_device, best_mount, best_type = fields[0], point, fields[2]
		}

		if best_mount == "" {
			return "", "", .Unknown, false
		}

		device = strings.clone(best_device, allocator)
		mount = strings.clone(best_mount, allocator)
		fs = filesystem_from_name(best_type)
		found = true

		return device, mount, fs, found
	}
}

/*
mounts_under is every mount point the mount table has at or below dir, in
allocator. dir must be a real path, as the table's points are, with no link or dot
in it. It reads /proc/mounts, which is Linux's; on another system, or when the
file cannot be read, there are none.
*/
mounts_under :: proc(dir: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	when ODIN_OS == .Linux {
		table, err := os.read_entire_file_from_path(PROC_MOUNTS, context.temp_allocator)
		if err != nil {
			return out[:]
		}
		text := string(table)
		point := strings.builder_make(context.temp_allocator)
		for line in strings.split_lines_iterator(&text) {
			rest := line
			_ = strings.fields_iterator(&rest) or_continue // the device
			field := strings.fields_iterator(&rest) or_continue
			strings.builder_reset(&point)
			unescape_to(&point, field)
			if covers(dir, strings.to_string(point)) {
				append(&out, strings.clone(strings.to_string(point), allocator))
			}
		}
	}
	return out[:]
}

@(private)
PROC_MOUNTS :: "/proc/mounts"

// A place the mount table shows a directory at: its path, and the id of the mount
// the path reaches it through.
Shown :: struct {
	path:  string,
	mount: u64,
}

/*
shown_elsewhere is every place at or under `under`, a real path, where the mount
table shows the directory that mount `id` has at its root, through another mount
of the same filesystem whose own root holds it: a bind of /var at /mnt/var is
shown at /var, through the mount of /. A mount with the same root as `id` counts
only when its id is the lower, so of two binds of one directory each finds the
other only one way round. Paths are in allocator. It reads /proc/self/mountinfo,
which is Linux's; on another system, or when the file cannot be read, there are
none.
*/
shown_elsewhere :: proc(id: u64, under: string, allocator := context.allocator) -> []Shown {
	out := make([dynamic]Shown, allocator)
	when ODIN_OS == .Linux {
		table, err := os.read_entire_file_from_path(PROC_MOUNTINFO, context.temp_allocator)
		if err != nil {
			return out[:]
		}
		mounts := mountinfo_parse(string(table))
		own, found := Mount_Line{}, false
		for m in mounts {
			if m.id == id {
				own, found = m, true
			}
		}
		if !found {
			return out[:]
		}
		for m in mounts {
			if m.id == own.id || m.device != own.device || !covers(m.root, own.root) {
				continue
			}
			if m.root == own.root && m.id > own.id {
				continue
			}
			// The part of own's root below m's, put under where m is mounted.
			rest := strings.trim_right(own.root[len(strings.trim_right(m.root, "/")):], "/")
			path := strings.concatenate(
				{strings.trim_right(m.point, "/"), rest},
				context.temp_allocator,
			)
			if path == "" {
				path = "/"
			}
			if covers(under, path) {
				append(&out, Shown{strings.clone(path, allocator), m.id})
			}
		}
	}
	return out[:]
}

@(private)
PROC_MOUNTINFO :: "/proc/self/mountinfo"

// The fields of one line of /proc/self/mountinfo that shown_elsewhere reads
// (proc_pid_mountinfo(5)): the mount's id, its device as major:minor, the
// directory of the filesystem at its root, and where it is mounted.
@(private)
Mount_Line :: struct {
	id:     u64,
	device: string,
	root:   string,
	point:  string,
}

// Every line of the table that has those fields, in the temp allocator.
@(private)
mountinfo_parse :: proc(text: string) -> []Mount_Line {
	out := make([dynamic]Mount_Line, context.temp_allocator)
	text := text
	for line in strings.split_lines_iterator(&text) {
		rest := line
		first := strings.fields_iterator(&rest) or_continue
		_ = strings.fields_iterator(&rest) or_continue // the parent's id
		device := strings.fields_iterator(&rest) or_continue
		root := strings.fields_iterator(&rest) or_continue
		point := strings.fields_iterator(&rest) or_continue
		id := strconv.parse_u64(first, 10) or_continue
		root = unescape(root, context.temp_allocator)
		point = unescape(point, context.temp_allocator)
		append(&out, Mount_Line{id, device, root, point})
	}
	return out[:]
}

// Whether `path` lies at or below `mount`. A prefix is not enough: /home does not
// cover /home2, only /home and what is under it.
@(private)
covers :: proc(mount, path: string) -> bool {
	if !strings.has_prefix(path, mount) {
		return false
	}
	return len(path) == len(mount) || strings.has_suffix(mount, "/") || path[len(mount)] == '/'
}

// The mount table escapes the characters that would otherwise end a field.
@(private)
unescape :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, `\`) {
		return s
	}
	b := strings.builder_make(allocator)
	unescape_to(&b, s)
	return strings.to_string(b)
}

// unescape_to writes s to b with the mount table's escapes undone.
@(private)
unescape_to :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) {
			v := (int(s[i + 1]) - '0') * 64 + (int(s[i + 2]) - '0') * 8 + (int(s[i + 3]) - '0')
			if v >= 0 && v < 256 {
				strings.write_byte(b, byte(v))
				i += 3
				continue
			}
		}
		strings.write_byte(b, s[i])
	}
}

// Only the filesystems a reader here could specialise for are named; everything else
// is walkable and nothing more.
@(private)
filesystem_from_name :: proc(name: string) -> Filesystem {
	switch name {
	case "ntfs", "ntfs3":
		return .Ntfs
	case "exfat":
		return .Exfat
	case "vfat", "msdos":
		return .Fat32
	case "nfs", "nfs4", "cifs", "smb3", "smbfs", "afpfs", "webdav":
		return .Network
	}
	return .Other
}
