package sonar_app

import "core:testing"

import "../../history"
import "../query"

// The store keeps what holds at least history.KEPT_MIN, and the view reads an
// entry missing from a snapshot as smaller than query.KEPT_MIN. Each package
// names its own, since query imports nothing; this holds them to one value.
@(test)
the_store_and_the_view_agree_on_what_is_kept :: proc(t: ^testing.T) {
	testing.expect_value(t, history.KEPT_MIN, query.KEPT_MIN)
}
