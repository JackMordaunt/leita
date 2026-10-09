package survey

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "../scan"

// ESTOILE_SYNTHETIC turns any target into a made-up disk, read by the synthetic
// reader through the same fill as a real one. Called off part way, the fill
// stops and says why, as a walk does.
@(test)
the_synthetic_variable_makes_the_disk_up :: proc(t: ^testing.T) {
	testing.expect(t, os.set_env(scan.SYNTHETIC_ENV, "3") == nil)
	target, choice, err := scan.resolve("/")
	os.unset_env(scan.SYNTHETIC_ENV)
	testing.expect_value(t, err, scan.Error.None)
	testing.expect_value(t, choice.engine, scan.Engine.Synthetic)
	defer scan.target_destroy(&target)

	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	f := Fill {
		target   = target,
		engine   = choice.engine,
		tree     = &tree,
		scanning = true,
	}
	defer fill_destroy(&f)
	reader := thread.create_and_start_with_poly_data(&f, fill_run)
	deadline := time.tick_now()
	for sync.atomic_load(&tree.nodes_done) < 1000 && time.tick_since(deadline) < 10 * time.Second {
		time.sleep(time.Millisecond)
	}
	scan.cancel(&tree)
	thread.join(reader)
	thread.destroy(reader)

	testing.expect_value(t, scan.name_of(&tree, tree.root), "/")
	testing.expect(t, sync.atomic_load(&tree.nodes_done) >= 1000, "it made entries up")
	testing.expect_value(t, problem(&f, context.temp_allocator), "making the disk up: Cancelled")
}
