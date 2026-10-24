package walk

import "core:testing"

import "../scan"

@(test)
test_windows_account_keeps_length_allocation_and_charge_apart :: proc(t: ^testing.T) {
	// Resident: reported 104 is not a cluster multiple. Charge becomes the
	// length. Allocated stays unknown, so the length is not a frees figure.
	charge, resident := windows_account({
		logical = 100,
		reported_allocation = 104,
		cluster = 4096,
		ntfs = true,
		links = 1,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(100))
	testing.expect(t, resident.known == nil)
	testing.expect(t, .Allocated not_in resident.known && .Reclaim not_in resident.known)

	// Occupied query succeeded. Allocated is that size, not the length and not
	// a later charge rewrite.
	compressed: scan.Account
	charge, compressed = windows_account({
		logical = 8192,
		reported_allocation = 8192,
		occupied = 100,
		occupied_known = true,
		compressed_or_sparse = true,
		cluster = 4096,
		ntfs = true,
		links = 1,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(8192))
	testing.expect_value(t, compressed.logical, u64(8192))
	testing.expect_value(t, compressed.allocated, u64(100))
	testing.expect(t, compressed.known == {.Logical, .Links, .Allocated})
	testing.expect(t, .Reclaim not_in compressed.known && .Exclusive not_in compressed.known)

	sparse: scan.Account
	charge, sparse = windows_account({
		logical = 1 << 20,
		reported_allocation = 1 << 20,
		occupied = 4096,
		occupied_known = true,
		compressed_or_sparse = true,
		cluster = 4096,
		ntfs = true,
		links = 1,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(4096))
	testing.expect_value(t, sparse.allocated, u64(4096))
	testing.expect_value(t, sparse.logical, u64(1 << 20))
	testing.expect(t, .Exclusive not_in sparse.known && .Reclaim not_in sparse.known)

	// The occupied query stops at the length, 4096, where NTFS holds a whole
	// compression unit, 64 KiB, which the reported allocation says.
	unit: scan.Account
	charge, unit = windows_account({
		logical = 4096,
		reported_allocation = 65536,
		occupied = 4096,
		occupied_known = true,
		compressed_or_sparse = true,
		cluster = 4096,
		ntfs = true,
		links = 1,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(65536))
	testing.expect_value(t, unit.allocated, u64(65536))
	testing.expect_value(t, unit.logical, u64(4096))

	// Occupied query failed. The reported size is not stored as Allocated.
	missed: scan.Account
	charge, missed = windows_account({
		logical = 8000,
		reported_allocation = 8192,
		compressed_or_sparse = true,
		cluster = 4096,
		ntfs = true,
		links = 1,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(8192))
	testing.expect_value(t, missed.logical, u64(8000))
	testing.expect(t, missed.known == {.Logical, .Links})
	testing.expect(t, .Allocated not_in missed.known)

	linked: scan.Account
	charge, linked = windows_account({
		logical = 100,
		reported_allocation = 4096,
		cluster = 4096,
		ntfs = true,
		links = 3,
		links_known = true,
	})
	testing.expect_value(t, charge, u64(4096))
	testing.expect_value(t, linked.links, u32(3))
	testing.expect_value(t, linked.shared, u64(4096))
	testing.expect_value(t, linked.allocated, u64(4096))
	testing.expect_value(t, linked.reclaim, u64(0))
	testing.expect(t, .Reclaim in linked.known && .Exclusive not_in linked.known)

	// Resident and linked: Exact 0 from the link count, shared not taken from the charge.
	_, resident_link := windows_account({
		logical = 100,
		reported_allocation = 104,
		cluster = 4096,
		ntfs = true,
		links = 2,
		links_known = true,
	})
	testing.expect(t, resident_link.known == {.Logical, .Links, .Reclaim})
	testing.expect_value(t, resident_link.logical, u64(100))
	testing.expect_value(t, resident_link.links, u32(2))
	testing.expect_value(t, resident_link.reclaim, u64(0))
	testing.expect_value(t, resident_link.shared, u64(0))
	testing.expect(t, .Allocated not_in resident_link.known && .Shared not_in resident_link.known)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect(t, scan.account_set(&tree, 0, compressed))
	testing.expect(t, scan.account_set(&tree, 1, linked))
	testing.expect(t, scan.account_set(&tree, 2, missed))
	f := scan.freed_of(&tree, 0)
	testing.expect_value(t, f.basis, scan.Basis.Charged)
	testing.expect_value(t, f.bytes, u64(0))
	f = scan.freed_of(&tree, 1)
	testing.expect_value(t, f.basis, scan.Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))
	f = scan.freed_of(&tree, 2)
	testing.expect_value(t, f.basis, scan.Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))
	f = scan.freed_of(&tree, 3)
	testing.expect_value(t, f.basis, scan.Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))
}

@(test)
test_file_account_does_not_label_scan_order_allocated :: proc(t: ^testing.T) {
	// Logical length differs from a scan-order charge. No Allocated fact.
	a := file_account({
		logical = 5000,
		charge = 1000,
		links = 1,
		links_known = true,
	})
	testing.expect(t, a.known == {.Logical, .Links})
	testing.expect(t, .Allocated not_in a.known && .Exclusive not_in a.known)

	same := file_account({
		logical = 1000,
		charge = 1000,
		links = 1,
		links_known = true,
	})
	testing.expect(t, same.known == nil)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree), scan.Error.None)
	defer scan.tree_destroy(&tree)
	scan.mark_scan_order(&tree)
	testing.expect(t, scan.account_set(&tree, 0, a))
	f := scan.freed_of(&tree, 0)
	testing.expect_value(t, f.basis, scan.Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))

	multi := file_account({
		logical = 5000,
		charge = 1000,
		links = 2,
		links_known = true,
	})
	testing.expect_value(t, multi.logical, u64(5000))
	testing.expect_value(t, multi.links, u32(2))
	testing.expect_value(t, multi.reclaim, u64(0))
	testing.expect(t, multi.known == {.Logical, .Links, .Reclaim})
	testing.expect(t, .Allocated not_in multi.known)
	testing.expect(t, scan.account_set(&tree, 1, multi))
	f = scan.freed_of(&tree, 1)
	testing.expect_value(t, f.basis, scan.Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))
}
