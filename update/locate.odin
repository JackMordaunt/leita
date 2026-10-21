package update

import "core:os"
import "core:strings"

// LINK_LIMIT bounds how many symlinks resolve_exe follows. A loop, or a
// chain longer than this, is a link and not a file to replace.
LINK_LIMIT :: 40

// resolve_exe is the file an update may replace. Symlinks are followed, so
// the lock and the scratch names sit beside that file and not beside one of
// its names. A missing path is still returned, cleaned, so a link to a
// package or Program Files path is refused before anything is created.
// ok is false for a loop, a path that is not a file, or a path that cannot
// be read; why says which.
resolve_exe :: proc(exe: string, allocator := context.temp_allocator) -> (real: string, why: Reason, ok: bool) {
	abs, aerr := absolute_of(exe)
	if aerr != nil {
		return "", .Cannot_Replace, false
	}
	cur := lexical_clean(abs)
	seen := make(map[string]struct{}, 8, allocator)
	for _ in 0 ..< LINK_LIMIT {
		if cur in seen {
			return "", .Link, false
		}
		seen[cur] = {}
		fi, err := os.lstat(cur, allocator)
		if err != nil {
			if err == .Not_Exist {
				return cur, .None, true
			}
			os.file_info_delete(fi, allocator)
			return "", .Cannot_Replace, false
		}
		kind := fi.type
		os.file_info_delete(fi, allocator)
		if kind == .Symlink {
			target, rerr := os.read_link(cur, allocator)
			if rerr != nil || len(target) == 0 {
				return "", .Link, false
			}
			next := target
			if !path_is_absolute(target) {
				next = join_path(parent_of(cur), target)
			}
			cur = lexical_clean(next)
			continue
		}
		if kind == .Regular {
			canon, cok := canonical_existing(cur)
			if !cok {
				return "", .Cannot_Replace, false
			}
			return lexical_clean(canon), .None, true
		}
		return "", .Cannot_Replace, false
	}
	return "", .Link, false
}

// Two hard links are two directory entries. The lock is on the resolved
// path, so it does not by itself cover a second hard link of the same inode.

@(private)
is_sep :: proc(c: byte) -> bool {
	when ODIN_OS == .Windows {
		return c == '/' || c == '\\'
	} else {
		return c == '/'
	}
}

@(private)
path_is_absolute :: proc(p: string) -> bool {
	if len(p) == 0 {
		return false
	}
	when ODIN_OS == .Windows {
		if len(p) >= 2 && is_sep(p[0]) && is_sep(p[1]) {
			return true
		}
		return len(p) >= 3 && p[1] == ':' && is_sep(p[2])
	} else {
		return p[0] == '/'
	}
}

@(private)
absolute_of :: proc(p: string, allocator := context.temp_allocator) -> (string, os.Error) {
	when ODIN_OS == .Windows {
		if len(p) >= 4 && is_sep(p[0]) && is_sep(p[1]) && p[2] == '?' {
			return p, nil
		}
	}
	if path_is_absolute(p) {
		return p, nil
	}
	cwd, err := os.get_working_directory(allocator)
	if err != nil {
		return "", err
	}
	when ODIN_OS == .Windows {
		if len(p) > 0 && is_sep(p[0]) && len(cwd) >= 2 && cwd[1] == ':' {
			return strings.concatenate({cwd[:2], p}, allocator), nil
		}
		if len(p) >= 2 && p[1] == ':' {
			rest := p[2:]
			if len(cwd) >= 2 && cwd[0] == p[0] && cwd[1] == ':' {
				return join_path(cwd, rest), nil
			}
		}
	}
	return join_path(cwd, p), nil
}

@(private)
join_path :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if len(dir) == 0 {
		return name
	}
	if is_sep(dir[len(dir) - 1]) {
		return strings.concatenate({dir, name}, allocator)
	}
	sep := "/"
	when ODIN_OS == .Windows {
		sep = "\\"
	}
	return strings.concatenate({dir, sep, name}, allocator)
}

// parent_of is the directory of p. A drive root and `/` stay roots.
parent_of :: proc(p: string) -> string {
	s := p
	if len(s) > 1 && is_sep(s[len(s) - 1]) {
		s = s[:len(s) - 1]
	}
	last := -1
	for i := len(s) - 1; i >= 0; i -= 1 {
		if is_sep(s[i]) {
			last = i
			break
		}
	}
	if last < 0 {
		return s
	}
	head := s[:last]
	if len(head) == 0 {
		return s[:last + 1]
	}
	when ODIN_OS == .Windows {
		if len(head) == 2 && head[1] == ':' {
			return s[:last + 1]
		}
	}
	return head
}

@(private)
lexical_clean :: proc(path: string, allocator := context.temp_allocator) -> string {
	p := path
	prefix: string
	rest: string
	fixed := 0
	when ODIN_OS == .Windows {
		if len(p) >= 8 && is_sep(p[0]) && is_sep(p[1]) && p[2] == '?' && is_sep(p[3]) {
			mark := p[4:7]
			if mark == "UNC" || mark == "unc" {
				if len(p) > 7 && is_sep(p[7]) {
					p = strings.concatenate({`\\`, p[8:]}, allocator)
				}
			} else if len(p) > 4 {
				p = p[4:]
			}
		}
		if len(p) >= 2 && is_sep(p[0]) && is_sep(p[1]) {
			prefix = `\\`
			rest = p[2:]
			fixed = 2
		} else if len(p) >= 2 && p[1] == ':' {
			rooted := len(p) >= 3 && is_sep(p[2])
			prefix = p[:2]
			if rooted {
				prefix = strings.concatenate({prefix, `\`}, allocator)
			}
			rest = p[2:]
		} else {
			rest = p
		}
	} else {
		if len(p) > 0 && p[0] == '/' {
			prefix = "/"
			rest = p[1:]
		} else {
			rest = p
		}
	}

	parts: [dynamic]string
	parts.allocator = allocator
	i := 0
	for i < len(rest) {
		for i < len(rest) && is_sep(rest[i]) {
			i += 1
		}
		if i >= len(rest) {
			break
		}
		j := i
		for j < len(rest) && !is_sep(rest[j]) {
			j += 1
		}
		part := rest[i:j]
		i = j
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			if len(parts) > fixed {
				pop(&parts)
			}
			continue
		}
		append(&parts, part)
	}
	return join_cleaned(prefix, parts[:])
}

@(private)
join_cleaned :: proc(prefix: string, parts: []string, allocator := context.temp_allocator) -> string {
	if len(parts) == 0 {
		return prefix
	}
	sep := "/"
	when ODIN_OS == .Windows {
		sep = "\\"
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, prefix)
	ends := len(prefix) > 0 && is_sep(prefix[len(prefix) - 1])
	for part, i in parts {
		if i > 0 || (prefix != "" && !ends) {
			strings.write_string(&b, sep)
		}
		strings.write_string(&b, part)
	}
	return strings.to_string(b)
}
