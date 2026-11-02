#+build linux, darwin, freebsd
package place

import "core:testing"

@(test)
xdg_history_uses_absolute_data_home_and_ignores_relative_values :: proc(t: ^testing.T) {
	for c in ([]struct {
			data, home, want: string,
		}{{"/srv/leita-data", "/home/ann", "/srv/leita-data/leita/history.db"}, {"/srv/leita-data", "", "/srv/leita-data/leita/history.db"}, {"", "/home/ann", "/home/ann/.local/share/leita/history.db"}, {"relative/data", "/home/ann", "/home/ann/.local/share/leita/history.db"}, {"relative/data", "", ""}, {"", "", ""}, {"/srv/Ünal 日本語", "/home/ann", "/srv/Ünal 日本語/leita/history.db"}}) {
		// Use the tracking allocator so incorrect returned ownership is caught.
		got := xdg_path(c.data, c.home, context.allocator)
		testing.expect_value(t, got, c.want)
		if got != "" {delete(got)}
	}
}
