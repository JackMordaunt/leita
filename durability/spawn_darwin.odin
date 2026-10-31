#+build darwin
package durability

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libsystem "system:System"

@(private = "file", default_calling_convention = "c")
foreign libsystem {
	posix_spawn_file_actions_init :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_destroy :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_adddup2 :: proc(actions: ^rawptr, from, to: c.int) -> posix.Errno ---
	posix_spawn_file_actions_addopen :: proc(
		actions: ^rawptr,
		fd: c.int,
		path: cstring,
		flags: c.int,
		mode: posix.mode_t,
	) -> posix.Errno ---
	posix_spawn :: proc(
		pid: ^posix.pid_t,
		path: cstring,
		actions: ^rawptr,
		attr: rawptr,
		argv: [^]cstring,
		envp: [^]cstring,
	) -> posix.Errno ---
}

@(private = "file")
NULL_DEVICE :: "/dev/null"

// spawn_child starts self with env. Standard error is stderr_fd. Standard input
// and output are /dev/null, as os.process_start leaves them.
spawn_child :: proc(
	self: string,
	env: []string,
	stderr_fd: uintptr,
) -> (
	child: os.Process,
	err: os.Error,
) {
	argv, cenv := spawn_args(self, env) or_return
	actions: rawptr
	if serr := posix_spawn_file_actions_init(&actions); serr != .NONE {
		return {}, os.Platform_Error(serr)
	}
	defer posix_spawn_file_actions_destroy(&actions)

	if serr := spawn_stdio(&actions, c.int(stderr_fd)); serr != .NONE {
		return {}, os.Platform_Error(serr)
	}
	pid: posix.pid_t
	serr := posix_spawn(&pid, argv[0], &actions, nil, raw_data(argv), raw_data(cenv))
	if serr != .NONE {
		return {}, os.Platform_Error(serr)
	}
	return os.process_open(int(pid))
}

@(private = "file")
spawn_args :: proc(self: string, env: []string) -> (argv, cenv: []cstring, err: os.Error) {
	ta := context.temp_allocator
	argv = make([]cstring, 2, ta)
	cself, aerr := strings.clone_to_cstring(self, ta)
	if aerr != nil {
		return nil, nil, aerr
	}
	argv[0] = cself
	cenv = make([]cstring, len(env) + 1, ta)
	for v, i in env {
		cenv[i], aerr = strings.clone_to_cstring(v, ta)
		if aerr != nil {
			return nil, nil, aerr
		}
	}
	return
}

@(private = "file")
spawn_stdio :: proc(actions: ^rawptr, stderr_fd: c.int) -> posix.Errno {
	if err := posix_spawn_file_actions_adddup2(actions, stderr_fd, posix.STDERR_FILENO); err != .NONE {
		return err
	}
	null := strings.clone_to_cstring(NULL_DEVICE, context.temp_allocator)
	rdwr := c.int(posix.O_RDWR)
	opened := posix_spawn_file_actions_addopen(actions, posix.STDIN_FILENO, null, rdwr, {})
	if opened != .NONE {
		return opened
	}
	return posix_spawn_file_actions_addopen(actions, 1, null, rdwr, {})
}
