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
	file := strings.concatenate({home_dir, "/file"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, "x") == nil)
	not_dir := strings.concatenate({file, "/../proj/node_modules"}, context.temp_allocator)
	testing.expect(
		t,
		!root_may_delete(not_dir, owner, who, 0, HOST),
		"a non-directory component does not cancel in the text",
	)
}
