#+build !windows
package scan

import "core:io"
import "core:os"
import "core:strings"

/*
Resolve what was given into a target backends can dispatch on.

Three shapes arrive here. A block device names a volume, a regular file is taken to
hold an image of one, and both are identified by the signature at the front of them.
A directory names a place inside a volume, which the mount table accounts for.

Reading a signature is not parsing a filesystem: saying which reader applies is this
layer's job, and doing it here keeps that job free of every backend, exactly as
asking Windows for a volume's filesystem name does.
*/
resolve :: proc(input: string, allocator := context.allocator) -> (t: Target, err: Error) {
	info, stat_err := os.stat(input, context.temp_allocator)
	if stat_err != nil {
		if stat_err == io.Error.Permission_Denied {
			return {}, .Access_Denied
		}
		return {}, .Target_Not_Found
	}
	path := info.fullpath

	t.allocator = allocator
	t.input = strings.clone(input, allocator)

	#partial switch info.type {
	case .Block_Device, .Regular:
		t.image = info.type == .Regular
		t.volume = strings.clone(path, allocator)
		fs, sig_err := signature(path)
		if sig_err != .None {
			target_destroy(&t)
			return {}, sig_err
		}
		t.fs = fs
		return t, .None

	case .Directory:
		device, mount, fs, found := mounted_at(path, allocator)
		if !found {
			target_destroy(&t)
			return {}, .Unsupported_Platform
		}
		t.volume = device
		t.mount = mount
		t.fs = fs
		// Whatever lies below the mount point is the subtree to report on. Kept so
		// that the mount point and this concatenate back into the path.
		if len(path) > len(mount) {
			t.root = strings.clone(path[len(mount):], allocator)
		}
		return t, .None
	}

	target_destroy(&t)
	return {}, .Target_Not_Found
}

/*
Whether this process can open a raw volume handle.

Always true by the time it is asked. Unix grants raw reads through permissions on the
device rather than a process token, and `resolve` only names a filesystem for a
volume whose front it managed to read, so a target that reached here already opened.
A volume that did not fails resolution with Access_Denied instead.
*/
elevated :: proc() -> bool {
	return true
}

/*
The filesystem whose signature sits at the front of a volume.

Every one of these writes its name into the boot sector, at one of two offsets: the
OEM field for the NTFS family, and the type field further in for FAT. Reading 512
bytes is enough to tell them apart, and enough to say that none of them match.
*/
@(private = "file")
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
@(private = "file")
mounted_at :: proc(path: string, allocator := context.allocator) -> (device, mount: string, fs: Filesystem, found: bool) {
	when ODIN_OS != .Linux {
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
		return strings.clone(best_device, allocator),
			strings.clone(best_mount, allocator),
			filesystem_from_name(best_type),
			true
	}
}

@(private = "file")
PROC_MOUNTS :: "/proc/mounts"

// Whether `path` lies at or below `mount`. A prefix is not enough: /home does not
// cover /home2, only /home and what is under it.
@(private = "file")
covers :: proc(mount, path: string) -> bool {
	if !strings.has_prefix(path, mount) {
		return false
	}
	return len(path) == len(mount) || strings.has_suffix(mount, "/") || path[len(mount)] == '/'
}

// The mount table escapes the characters that would otherwise end a field.
@(private = "file")
unescape :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, `\`) {
		return s
	}
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) {
			v := (int(s[i + 1]) - '0') * 64 + (int(s[i + 2]) - '0') * 8 + (int(s[i + 3]) - '0')
			if v >= 0 && v < 256 {
				strings.write_byte(&b, byte(v))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// Only the filesystems a reader here could specialise for are named; everything else
// is walkable and nothing more.
@(private = "file")
filesystem_from_name :: proc(name: string) -> Filesystem {
	switch name {
	case "ntfs", "ntfs3":
		return .Ntfs
	case "exfat":
		return .Exfat
	case "vfat", "msdos":
		return .Fat32
	case "nfs", "nfs4", "cifs", "smb3":
		return .Network
	}
	return .Other
}
