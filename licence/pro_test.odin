package leita_licence

import "core:testing"
import "core:time"

/*
Pro runs during the 30-day evaluation. Once that clock is over, only
pro_for_this_build remains, and it applies the paid-through cutoff. A
development build has no release stamp, so a line does not keep Pro there.
*/
@(test)
pro_follows_the_evaluation_and_an_unstamped_build_stays_free :: proc(t: ^testing.T) {
	now := time.unix(1_800_000_000, 0)
	later := time.time_add(now, TRIAL_DAYS * DAY)
	none := Licence{}
	line := Licence {
		format       = .Annual,
		features     = FEATURES_PRO,
		paid_through = "2027-10-19T00:00:00Z",
	}
	testing.expect(t, entitled_to_pro(none, now, now), "the evaluation covers Pro")
	testing.expect(t, !entitled_to_pro(none, now, later), "after it, Free only")
	testing.expect(t, entitled_to_pro(line, now, now), "the evaluation covers Pro with a line too")
	// This binary has no release stamp, so pro_for_this_build is false for every
	// line. The instants where a stamp is inside or past paid_through are
	// pro_entitled's tests. Here the evaluation is the only grant left.
	testing.expect(t, !pro_for_this_build(line), "this build has no release stamp")
	testing.expect(
		t,
		!entitled_to_pro(line, TRIAL_OVER, later),
		"with the evaluation over, an unstamped build stays Free",
	)
}
