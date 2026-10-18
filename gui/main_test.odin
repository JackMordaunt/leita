package main

import "core:testing"

// A flag, help and version among them, makes Leita leita; a path, or nothing,
// opens the window. Two paths go to leita, which says what is wrong with them.
@(test)
a_flag_makes_leita_the_command_line :: proc(t: ^testing.T) {
	testing.expect_value(t, launch({}), Launch.Window)
	testing.expect_value(t, launch({"/tmp"}), Launch.Window)
	testing.expect_value(t, launch({"-h"}), Launch.Terminal)
	testing.expect_value(t, launch({"--version"}), Launch.Terminal)
	testing.expect_value(t, launch({"/tmp", "--report", "-", "--format", "json"}), Launch.Terminal)
	testing.expect_value(t, launch({"--no-history", "/tmp"}), Launch.Terminal)
	testing.expect_value(t, launch({"monitor", "-h"}), Launch.Terminal)
	testing.expect_value(t, launch({"journal"}), Launch.Terminal)
	testing.expect_value(t, launch({"licence"}), Launch.Terminal)
	testing.expect_value(t, launch({"history"}), Launch.Terminal)
	testing.expect_value(t, launch({"a", "b"}), Launch.Terminal)
}

// Finder's -psn_ argument is dropped, so an app opened from it with no
// argument, or with a path dropped on it, opens the window rather than refusing
// a flag; every other argument is kept, in order.
@(test)
a_process_serial_number_is_not_a_flag :: proc(t: ^testing.T) {
	alone := []string{"-psn_0_1234567"}
	testing.expect_value(t, len(without_psn(alone)), 0)
	testing.expect_value(t, launch(without_psn(alone)), Launch.Window)

	dropped := []string{"-psn_0_1234567", "/Volumes/Backup"}
	kept := without_psn(dropped)
	testing.expect_value(t, len(kept), 1)
	testing.expect_value(t, kept[0], "/Volumes/Backup")
	testing.expect_value(t, launch(kept), Launch.Window)

	flags := []string{"/tmp", "--report", "-"}
	testing.expect_value(t, len(without_psn(flags)), 3)
	testing.expect_value(t, launch(without_psn(flags)), Launch.Terminal)
}
