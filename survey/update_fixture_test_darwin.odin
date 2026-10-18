package survey

import "../scan"

fixture_requires_full :: proc(root: string) -> bool {
	st, ok := scan.stat_fs(root)
	return !ok || string(cstring(&st.fstypename[0])) == "apfs"
}
