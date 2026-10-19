#+build windows
package leita_files

import "core:strings"
import "core:testing"

import "../../home"

// Sizing the Recycle Bin is read-only. Emptying is never asked of a real volume.
@(test)
the_recycle_bin_is_sized_per_volume_and_empty_refuses_a_non_bin :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(SHQUERYRBINFO), 24)
	testing.expect_value(t, empty_recycle_bin(""), Error.Missing)
	testing.expect_value(t, empty_recycle_bin("not-a-drive"), Error.Missing)
	testing.expect_value(t, empty_recycle_bin(`/tmp`), Error.Missing)
	testing.expect_value(t, empty_recycle_bin(`C:\Users`), Error.Missing)
	_, _, ok := recycle_bin_info("")
	testing.expect(t, !ok, "no volume is not every drive")
	_, _, ok = recycle_bin_info("not-a-drive")
	testing.expect(t, !ok)

	u := home.user()
	defer home.user_destroy(&u)
	testing.expect(t, strings.has_prefix(u.uid, "S-1-"), "the account SID")
	bins := recycle_bins(u.uid, context.temp_allocator)
	testing.expect(t, len(bins) >= 1, "this machine has a volume the shell will query")
	found := false
	for b in bins {
		testing.expect(t, len(b.volume) >= 3 && b.volume[1] == ':', "a volume root")
		testing.expect(t, strings.contains(b.path, "$Recycle.Bin"), b.path)
		testing.expect(t, strings.has_suffix(b.path, u.uid), "this user's folder")
		bytes, items, queried := recycle_bin_info(b.volume)
		testing.expect(t, queried, b.volume)
		if b.volume[0] == 'C' || b.volume[0] == 'c' {
			found = true
			testing.expect_value(t, bytes, b.bytes)
			testing.expect_value(t, items, b.items)
		}
	}
	testing.expect(t, found, "C: is among them")
	letter, has := drive_letter(
		strings.concatenate({`C:\$Recycle.Bin\`, u.uid}, context.temp_allocator),
	)
	testing.expect(t, has && letter == 'C')
	letter, has = drive_letter(`D:\`)
	testing.expect(t, has && letter == 'D')
	_, has = drive_letter(`C:\Windows`)
	testing.expect(t, !has, "a folder on the volume is not the bin")
}
