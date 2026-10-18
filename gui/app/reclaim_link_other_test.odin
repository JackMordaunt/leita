#+build !windows
package leita_app

import "core:os"

// link_directory makes path a symbolic link to the directory target. Windows
// makes a junction instead (reclaim_link_windows_test.odin): core:os's symlink
// is unsupported there, and a junction is what Reclaim must not offer. Not
// symlink_directory: that helper's Windows side is CreateSymbolicLinkW.
//review:ignore matches-neighbours This helper creates a Windows junction; symlink_directory creates a symbolic link.
link_directory :: proc(target, path: string) -> bool {
	return os.symlink(target, path) == nil
}
