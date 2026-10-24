#+build !windows
package survey

import "../faults"

// Rename `from` over `to`; rename(2) replaces it whatever else has it open.
@(private)
replace :: proc(from, to: string) -> bool {
	return faults.rename(from, to) == nil
}
