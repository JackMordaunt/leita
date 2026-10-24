#+build darwin
package walk_fuzz

import "core:strings"
import "core:testing"

// The temp directory lies behind the firmlink /private, so the scan property also
// walks each start by its path on the data volume.
@(test)
a_start_has_its_data_volume_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec{nodes = []Node{{id = 0, parent = NONE, kind = .Dir, target = NONE}}}
	fx: Fixture
	defer destroy(&fx)

	testing.expect_value(t, build(spec, &fx), "")
	found := aliases(&fx, 0)
	want := strings.concatenate({"/System/Volumes/Data", fx.root})
	testing.expectf(t, len(found) == 1 && found[0] == want, "aliases of %s: %v", fx.root, found)
}
