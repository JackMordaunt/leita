/*
Pro is the one paid feature set: comparing scans and how they grow, scheduled
scans and recurring delivery, reusable client and reporting profiles,
customised client and before-after reports, and consolidated analysis across
machines. Personal, Professional and Organisation differ in who may use Pro,
not in which of it runs.

Free, with or without a licence, and for an organisation as well as a person,
is a complete scan, its charts and search, safe cleanup, the log of that
cleanup, a CSV or JSON of the current scan, and opening records already kept.
None of that calls entitled_to_pro.

entitled_to_pro is the one gate. A line grants Pro only when
pro_for_this_build says this release is at or before its paid-through date,
which a build with no release stamp never is. The 30-day evaluation grants Pro
while it still has days left, with or without a line. unlocked is the older
question and does not apply the cutoff, so a gate does not call it.
*/
package leita_licence

import "core:time"

// entitled_to_pro says whether Pro runs at now. l is the licence this build
// has checked, or the zero Licence when there is none. first is when the
// 30-day evaluation began, now the clock it is read by.
entitled_to_pro :: proc(l: Licence, first, now: time.Time) -> bool {
	return pro_for_this_build(l) || days_left(first, now) > 0
}
