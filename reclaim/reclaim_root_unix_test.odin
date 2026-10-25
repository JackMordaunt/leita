#+build !windows
package reclaim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../home"

// The resolution this root check performs follows a symlink in the path. Root
// may delete only when the resolved path is still under the home, not merely
// when the text of the path begins with the home. The platform is HOST: on
// macOS HOST is Darwin, and passing .Unix would skip realpath.
@(test)
root_refuses_a_symlink_that_leaves_the_home :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/leita-reclaim-root-%d", os.get_pid())
	os.remove_all(base)
	defer os.remove_all(base)

	home_dir := strings.concatenate({base, "/home/ann"}, context.temp_allocator)
	mine := strings.concatenate({home_dir, "/proj/node_modules"}, context.temp_allocator)
	outside := strings.concatenate({base, "/outside/node_modules"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(mine) == nil)
	testing.expect(t, os.make_directory_all(outside) == nil)

	who := home.User{home_dir, fmt.tprintf("%d", u32(posix.getuid()))}
	owner := u32(posix.getuid())
	testing.expect(t, root_may_delete(mine, owner, who, 0, HOST), "her own directory")

	alias := strings.concatenate({home_dir, "/alias"}, context.temp_allocator)
	proj := strings.concatenate({home_dir, "/proj"}, context.temp_allocator)
	testing.expect(t, os.symlink(proj, alias) == nil)
	inside := strings.concatenate({alias, "/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		root_may_delete(inside, owner, who, 0, HOST),
		"a symlink that stays under her home",
	)

	link := strings.concatenate({home_dir, "/link"}, context.temp_allocator)
	out := strings.concatenate({base, "/outside"}, context.temp_allocator)
	testing.expect(t, os.symlink(out, link) == nil)
	escaped := strings.concatenate({link, "/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(escaped, owner, who, 0, HOST),
		"a symlink ancestor resolves outside the home",
	)

	// ".." is applied by the kernel after the symlink is followed. Collapsing it
	// in the text first cancels the link and leaves a different directory, the
	// one planted inside the home, which is not the directory an open reaches.
	decoy := strings.concatenate({home_dir, "/victim"}, context.temp_allocator)
	victim := strings.concatenate({base, "/victim"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(decoy) == nil)
	testing.expect(t, os.make_directory_all(victim) == nil)
	through := strings.concatenate({link, "/../victim"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(through, owner, who, 0, HOST),
		"dotdot through a symlink leaves the home",
	)
	gone := strings.concatenate({link, "/../gone"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(gone, owner, who, 0, HOST),
		"a missing name after that dotdot is still outside",
	)

	alias_dot := strings.concatenate({alias, "/../proj/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		root_may_delete(alias_dot, owner, who, 0, HOST),
		"dotdot that stays under her home",
	)
	missing := strings.concatenate({home_dir, "/no-such/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		root_may_delete(missing, owner, who, 0, HOST),
		"a missing directory still inside the home",
	)

	loop := strings.concatenate({home_dir, "/loop"}, context.temp_allocator)
	testing.expect(t, os.symlink("loop", loop) == nil)
	looped := strings.concatenate({loop, "/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(looped, owner, who, 0, HOST),
		"a symlink loop is not proof the directory stays inside",
	)
	// The text spells her own directory. The file is not a directory, so ".."
	// does not enter it and must not count as her node_modules.
	file := strings.concatenate({home_dir, "/file"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, "x") == nil)
	not_dir := strings.concatenate({file, "/../proj/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(not_dir, owner, who, 0, HOST),
		"a non-directory component does not cancel in the text",
	)
	// The same file, then enough ".." to spell the outside directory. Cancelling
	// through the file would leave the home; stopping at the file must too.
	leapt := strings.concatenate({file, "/../../outside/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(leapt, owner, who, 0, HOST),
		"a non-directory component does not let .. leave the home",
	)
}

// A directory under the home deeper than PATH_MAX, which the walk reads since card
// 771, is refused to root: realpath cannot resolve it, and a path root cannot
// resolve is never one it deletes, though its text lies under the home.
@(test)
root_refuses_a_path_past_path_max :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/leita-reclaim-deep-%d", os.get_pid())
	home_dir := strings.concatenate({base, "/home/ann"}, context.temp_allocator)
	step := strings.repeat("p", 100, context.temp_allocator)
	cstep := strings.clone_to_cstring(step, context.temp_allocator)
	DEPTH :: 60

	// Made and removed with *at calls, since no path reaches the bottom.
	remove :: proc(home_dir: string, cstep: cstring) {
		fds: [DEPTH + 1]posix.FD
		fds[0] = posix.open(strings.clone_to_cstring(home_dir, context.temp_allocator), {.DIRECTORY})
		if fds[0] < 0 {
			return
		}
		depth := 0
		for depth < DEPTH {
			next := posix.openat(fds[depth], cstep, {.DIRECTORY})
			if next < 0 {
				break
			}
			depth += 1
			fds[depth] = next
		}
		for depth > 0 {
			posix.close(fds[depth])
			depth -= 1
			posix.unlinkat(fds[depth], cstep, {.REMOVEDIR})
		}
		posix.close(fds[0])
	}
	remove(home_dir, cstep)
	os.remove_all(base)
	defer os.remove_all(base)
	defer remove(home_dir, cstep)

	testing.expect(t, os.make_directory_all(home_dir) == nil)

	at := posix.open(strings.clone_to_cstring(home_dir, context.temp_allocator), {.DIRECTORY})
	if !testing.expect(t, at >= 0, "could not open the home") {
		return
	}
	deep := strings.builder_make(context.temp_allocator)
	strings.write_string(&deep, home_dir)
	for _ in 0 ..< DEPTH {
		testing.expect(t, posix.mkdirat(at, cstep, {.IRUSR, .IWUSR, .IXUSR}) == .OK)
		next := posix.openat(at, cstep, {.DIRECTORY})
		posix.close(at)
		if !testing.expect(t, next >= 0, "could not open a step") {
			return
		}
		at = next
		strings.write_byte(&deep, '/')
		strings.write_string(&deep, step)
	}
	posix.close(at)

	who := home.User{home_dir, fmt.tprintf("%d", u32(posix.getuid()))}
	owner := u32(posix.getuid())
	testing.expect(
		t,
		!root_may_delete(strings.to_string(deep), owner, who, 0, HOST),
		"a path past PATH_MAX was let through",
	)
	shallow := strings.concatenate({home_dir, "/", step}, context.temp_allocator)
	testing.expect(t, root_may_delete(shallow, owner, who, 0, HOST), "the top of the same chain")
}
