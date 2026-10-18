package survey

import "core:strings"
import "core:sys/linux"

// The Linux fixture needs a fresh scan when its extent identities are absent.
fixture_requires_full :: proc(root: string) -> bool {
	st: linux.Stat_FS
	path := strings.clone_to_cstring(root, context.temp_allocator)
	return linux.statfs(path, &st) != .NONE || st.type == .BTRFS_SUPER_MAGIC
}
