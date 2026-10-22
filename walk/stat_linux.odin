#+build linux
package walk

import "../kstat"

// The walk's statx: kstat's, which is fstatat where the kernel has no statx.
statx_compat :: kstat.statx
