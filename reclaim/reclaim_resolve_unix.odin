#+build !windows
package reclaim

import "core:strings"
import "core:sys/posix"

// host_confine is where path leads on this machine, in the temp allocator.
// Each component is resolved on its own, and ".." is applied only after a
// directory that was entered. One realpath of the whole text is not proof:
// it can name the parent of a file, so a path that never entered the file
// looks like a path inside the home. Collapsing ".." in the text first would
// also cancel a symlink and name a different directory, which the symlink
// test records. A missing tail stays on the last directory that resolved.
// The buffer is walk.Path, 4096 bytes.
@(private)
host_confine :: proc(path: string) -> Confinement {
	if path == "" {
		return {"", true}
	}
	parts := split_components(path)
	cur: string
	if path[0] == '/' {
		cur = "/"
	} else if got, how := resolve("."); how == .Found {
		cur = got
	} else {
		return {"", false}
	}
	for part, i in parts {
		switch part {
		case "", ".":
			continue
		case "..":
			// ".." of a file is not the parent. Refuse rather than cancel it.
			if !is_directory(cur) {
				return {"", false}
			}
			cur = dir_parent(cur)
			continue
		}
		// The next name is inside cur, so cur has to be a directory. A file
		// here is the same refusal as ".." after it: the rest was not walked.
		if !is_directory(cur) {
			return {"", false}
		}
		got, how := resolve(join_path(cur, part))
		switch how {
		case .Found:
			cur = got
		case .Missing:
			tail, known := finish_lexical(cur, parts[i:])
			return {tail, known}
		case .Failed:
			return {"", false}
		}
	}
	return {cur, true}
}

// is_directory is whether path, already resolved, is a directory. A stat
// failure is not a directory: a component that cannot be shown to be one
// does not let the rest of the path through.
@(private)
is_directory :: proc(path: string, allocator := context.temp_allocator) -> bool {
	if path == "" {
		return false
	}
	st: posix.stat_t
	cpath := strings.clone_to_cstring(path, allocator)
	if posix.stat(cpath, &st) != .OK {
		return false
	}
	return posix.S_ISDIR(st.st_mode)
}

@(private)
Resolution :: enum {
	Found,
	Missing,
	Failed,
}

// resolve is path with every symlink followed, or Missing when realpath
// reports ENOENT. Any other realpath failure is Failed.
@(private)
resolve :: proc(path: string) -> (string, Resolution) {
	if path == "" {
		return "", .Failed
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	buf: [4096]byte
	if posix.realpath(cpath, raw_data(buf[:])) == nil {
		if posix.errno() == .ENOENT {
			return "", .Missing
		}
		return "", .Failed
	}
	return strings.clone(string(cstring(&buf[0])), context.temp_allocator), .Found
}

@(private)
split_components :: proc(path: string) -> []string {
	parts := make([dynamic]string, context.temp_allocator)
	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i < len(path) && path[i] != '/' {
			continue
		}
		append(&parts, path[start:i])
		start = i + 1
	}
	return parts[:]
}

@(private)
join_path :: proc(dir, name: string) -> string {
	if dir == "/" {
		return strings.concatenate({"/", name}, context.temp_allocator)
	}
	if dir == "" {
		return name
	}
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

@(private)
dir_parent :: proc(path: string) -> string {
	if path == "" || path == "/" {
		return "/"
	}
	n := strings.last_index_byte(path, '/')
	if n <= 0 {
		return "/"
	}
	return path[:n]
}

// finish_lexical appends parts, which were not on disk, onto dir. ".." cancels
// one of those parts only. If ".." would climb past them, it returns "", false.
@(private)
finish_lexical :: proc(dir: string, parts: []string) -> (string, bool) {
	cur := dir
	extra := 0
	for part in parts {
		switch part {
		case "", ".":
		case "..":
			if extra == 0 {
				return "", false
			}
			cur = dir_parent(cur)
			extra -= 1
		case:
			cur = join_path(cur, part)
			extra += 1
		}
	}
	return cur, true
}
