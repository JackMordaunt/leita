package journal

import "core:fmt"
import "core:strings"

// The recorder's service, the copy of leita it runs, and where those live when
// leita journal on installs them, as from the release archive.
SERVICE     :: "leita-journal.service"
UNIT_PATH   :: "/etc/systemd/system/" + SERVICE
BINARY_DIR  :: "/usr/local/libexec/leita"
BINARY_PATH :: BINARY_DIR + "/leita"

// Where the .deb and .rpm put them instead (packaging/linux): the package owns
// both, installing and removing them, and leita journal on only enables the
// service. The unit is packaging/linux/leita-journal.service, unit_text of
// PACKAGE_BINARY_PATH, as a test holds.
PACKAGE_UNIT_PATH   :: "/usr/lib/systemd/system/" + SERVICE
PACKAGE_BINARY_PATH :: "/usr/libexec/leita/leita"

/*
unit_text is the recorder's system service, running binary. It runs a
root-owned copy of leita, since a system service must not run a program its user
can rewrite, with only the two capabilities fanotify needs: CAP_SYS_ADMIN to mark
a filesystem (fanotify_mark(2)) and CAP_DAC_READ_SEARCH to open a directory by
its handle (open_by_handle_at(2)). The rest of the system is read-only to it
but its own folder.
*/
unit_text :: proc(binary := BINARY_PATH, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "[Unit]\nDescription=leita: record which folders change\n\n")
	strings.write_string(&b, "[Service]\nType=simple\n")
	fmt.sbprintf(&b, "ExecStart=%s journal run\n", binary)
	strings.write_string(&b, "Restart=on-failure\n")
	strings.write_string(&b, "CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH\n")
	strings.write_string(&b, "AmbientCapabilities=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH\n")
	strings.write_string(&b, "NoNewPrivileges=yes\nProtectSystem=strict\n")
	fmt.sbprintf(&b, "ReadWritePaths=%s\n", STATE_DIR)
	strings.write_string(
		&b,
		"# Not ProtectHome: the recorder opens the folders that change to name them,\n" +
		"# and most of them are under /home.\n",
	)
	strings.write_string(&b, "\n[Install]\nWantedBy=multi-user.target\n")
	return strings.to_string(b)
}
