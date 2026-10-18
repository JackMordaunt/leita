package scan

import "core:sync"

// A fact a reader measured. A missing fact is unknown. Zero is a measurement
// only when the fact is set.
Fact :: enum u8 {
	Logical, // apparent length (EOF / st_size); not space
	Allocated, // bytes the volume set aside, holes and compression removed
	Links, // name count
	Exclusive, // bytes no other live name or clone in this scan shares
	Shared, // bytes also referenced by another live file, clone, or name
	Held, // bytes a snapshot retains for this file
	Scan_Order, // this node's charge is a first payer; prefer mark_scan_order for a whole tree
	Reclaim, // a reclaim quantity the caller already proved; this package does not derive one
}
Facts :: distinct bit_set[Fact; u8]

// What a reader measured for one node. Fields whose fact is clear are unknown,
// not zero. Callers pass this to account_set; the tree stores it packed.
Account :: struct {
	logical:   u64,
	allocated: u64,
	exclusive: u64,
	shared:    u64,
	held:      u64,
	reclaim:   u64,
	links:     u32,
	known:     Facts,
}

// How far a frees figure can be trusted. Only Exact has a quantity, and this
// package does not treat that quantity as bytes the operating system will free.
// Charged is an allocated or accounted estimate and carries no frees quantity.
// Unknown is explicit. Exclusive allocation is not consulted, and exclusive
// minus held is not computed.
Basis :: enum u8 {
	Unknown,
	Charged,
	Exact,
}

// bytes is 0 unless basis is Exact. A caller must not display or serialize
// bytes for any other basis.
Freed :: struct {
	bytes: u64,
	basis: Basis,
}

// Whether this scan looked for snapshots. Unchecked and None are not proof
// that deletion frees the allocation. Present means a snapshot may retain
// bytes this node did not measure.
Snapshot_State :: enum u8 {
	Unchecked,
	None,
	Present,
}

// Volume-level retention. purgeable is not copied onto each file.
Retention :: struct {
	snapshots:       Snapshot_State,
	purgeable:       u64,
	purgeable_known: bool,
}

// One node's common facts. 24 bytes, so a block of them is one allocation
// rather than a heap object per node. known is stored last, atomically.
@(private)
Account_Common :: struct {
	logical:   u64,
	allocated: u64,
	links:     u32,
	known:     u8,
	state:     u8, // 0 empty, ACCOUNT_CLAIMED, ACCOUNT_PUBLISHED
	_pad:      [2]u8,
}

// Rare facts. A block of these exists only when some value in it is non-zero.
// A set fact and a missing block read back as 0.
@(private)
Account_Rare :: struct {
	exclusive: u64,
	shared:    u64,
	held:      u64,
	reclaim:   u64,
}

@(private)
Account_Block :: [BLOCK_NODES]Account_Common

@(private)
Rare_Block :: [BLOCK_NODES]Account_Rare

// The pointers to every block of accounts and of rare facts, one pair of tables
// per tree. Heap-allocated by the first account_set (Tree.facts).
Fact_Tables :: struct {
	accounts: [MAX_BLOCKS]^Account_Block,
	rares:    [MAX_BLOCKS]^Rare_Block,
}

#assert(size_of(Account_Common) == 24) //review:ignore commented-out-code a compile-time size check, not commented-out code
#assert(size_of(Account_Rare) == 32) //review:ignore commented-out-code a compile-time size check, not commented-out code
#assert(size_of(Node) == 24) //review:ignore commented-out-code a compile-time size check, not commented-out code

@(private)
ACCOUNT_CLAIMED :: u8(1)

@(private)
ACCOUNT_PUBLISHED :: u8(2)

@(private)
RETENTION_CLAIMED :: u8(1)

@(private)
RETENTION_PUBLISHED :: u8(2)

// Bytes of common sidecar for `nodes` that all carry a fact, including the
// partially filled last block. Nodes with no account_set add nothing; this is
// the cap when every node has one.
account_common_bytes :: proc(nodes: u64) -> u64 {
	if nodes == 0 {
		return 0
	}
	blocks := (nodes + BLOCK_NODES - 1) / BLOCK_NODES
	return blocks * u64(size_of(Account_Block))
}

/*
Record a's facts at the node index. The slot is the node's index and does not move.

Publication is immutable and one writer per node. The claim is a compare-exchange
on state, from empty to claimed, before any field is written. A second call finds
the claim taken, writes nothing, and returns false; the first values stay.
Clearing known and writing again is not safe: a reader can load the old known and
then read fields mid-rewrite.

False also when the index cannot be addressed or a block cannot be allocated.
An empty known set is not a publication: absence stays unknown.
*/
account_set :: proc(t: ^Tree, index: u32, a: Account) -> bool {
	if a.known == nil {
		return true
	}
	block := index >> BLOCK_SHIFT
	if block >= MAX_BLOCKS {
		return false
	}
	if !ensure_account(t, block) {
		return false
	}
	slot := index & (BLOCK_NODES - 1)
	common := &t.facts.accounts[block][slot]
	if _, claimed := sync.atomic_compare_exchange_strong_explicit(
		&common.state,
		0,
		ACCOUNT_CLAIMED,
		.Acquire,
		.Acquire,
	); !claimed {
		return false
	}
	rare := a.exclusive != 0 || a.shared != 0 || a.held != 0 || a.reclaim != 0
	if rare && !ensure_rare(t, block) {
		sync.atomic_compare_exchange_strong_explicit(
			&common.state,
			ACCOUNT_CLAIMED,
			0,
			.Release,
			.Relaxed,
		)
		return false
	}
	common.logical = a.logical
	common.allocated = a.allocated
	common.links = a.links
	common.known = transmute(u8)a.known
	if rare {
		r := &t.facts.rares[block][slot]
		r.exclusive = a.exclusive
		r.shared = a.shared
		r.held = a.held
		r.reclaim = a.reclaim
	}
	sync.atomic_store_explicit(&common.state, ACCOUNT_PUBLISHED, .Release)
	return true
}

// The account at index. ok is false when that node was never given a fact,
// which is also how a baseline that kept only Node.disk reads back.
account_of :: proc(t: ^Tree, index: u32) -> (a: Account, ok: bool) {
	block := index >> BLOCK_SHIFT
	if block >= MAX_BLOCKS {
		return
	}
	tables := sync.atomic_load(&t.facts)
	if tables == nil {
		return
	}
	common_block := sync.atomic_load(&tables.accounts[block])
	if common_block == nil {
		return
	}
	common := &common_block[index & (BLOCK_NODES - 1)]
	// Published is the only state whose fields are stable. Claimed means the
	// one writer is still filling them; reading there would tear.
	if sync.atomic_load_explicit(&common.state, .Acquire) != ACCOUNT_PUBLISHED {
		return
	}
	a.known = transmute(Facts)common.known
	a.logical = common.logical
	a.allocated = common.allocated
	a.links = common.links
	if rare_block := sync.atomic_load(&tables.rares[block]); rare_block != nil {
		rare := &rare_block[index & (BLOCK_NODES - 1)]
		a.exclusive = rare.exclusive
		a.shared = rare.shared
		a.held = rare.held
		a.reclaim = rare.reclaim
	}
	ok = true
	return
}

/*
Record volume retention once. Same lifetime as an account: one writer claims,
fills every field, then publishes. A second call returns false and leaves the
first record. Readers see either nothing (Unchecked, purgeable unknown) or the
finished record, never a mix of two notes. Snapshot names are not stored here.
*/
note_retention :: proc(t: ^Tree, r: Retention) -> bool {
	if _, claimed := sync.atomic_compare_exchange_strong_explicit(
		&t.retention_state,
		0,
		RETENTION_CLAIMED,
		.Acquire,
		.Acquire,
	); !claimed {
		return false
	}
	t.purgeable = r.purgeable
	t.purgeable_known = b32(r.purgeable_known)
	t.snapshots = u8(r.snapshots)
	sync.atomic_store_explicit(&t.retention_state, RETENTION_PUBLISHED, .Release)
	return true
}

// The published retention. Unpublished is the zero value: Unchecked, no purgeable figure.
retention_of :: proc(t: ^Tree) -> Retention {
	if sync.atomic_load_explicit(&t.retention_state, .Acquire) != RETENTION_PUBLISHED {
		return {}
	}
	return {
		snapshots = Snapshot_State(t.snapshots),
		purgeable = t.purgeable,
		purgeable_known = bool(t.purgeable_known),
	}
}

/*
What deleting this one node frees.

Exact is the only basis whose bytes may be shown or serialized. Two proofs
reach it: this name is not the one holding the data (an extra name, or a link
count above one), so the quantity is 0, or the caller stored Reclaim. Neither
is a guarantee the volume's free space changes by that amount.

Charged means an allocated size was measured. Its Freed.bytes is 0; the
estimate stays on Account.allocated and Node.disk. Everything unproved,
including a node whose disk was copied forward with no account, is Unknown.
*/
freed_of :: proc(t: ^Tree, index: u32) -> Freed {
	flags: Node_Flags
	if n := node(t, index); n != nil {
		flags = node_flags(n)
	}
	a, ok := account_of(t, index)
	if .Extra_Name in flags {
		return {basis = .Exact}
	}
	if ok && .Links in a.known && a.links > 1 {
		return {basis = .Exact}
	}
	if ok && .Reclaim in a.known {
		return {bytes = a.reclaim, basis = .Exact}
	}
	if is_scan_order(t) || is_logical(t) || (ok && .Scan_Order in a.known) {
		return {}
	}
	if retention_of(t).snapshots == .Present {
		return {}
	}
	if ok && .Shared in a.known || .Shared in flags {
		return {}
	}
	if ok && .Allocated in a.known {
		return {basis = .Charged}
	}
	return {}
}

// The tables of block pointers, made by the first account. Once published they
// are never replaced, so a reader that sees them sees them whole.
@(private)
ensure_tables :: proc(t: ^Tree, allocator := context.allocator) -> ^Fact_Tables {
	if tables := sync.atomic_load(&t.facts); tables != nil {
		return tables
	}
	sync.guard(&t.mutex)
	if t.facts != nil {
		return t.facts
	}
	tables, err := new(Fact_Tables, allocator)
	if err != nil {
		return nil
	}
	sync.atomic_store(&t.facts, tables)
	return tables
}

// Two procedures, not one: each allocates a different block type, and folding
// them erases that type. //review:ignore duplicate-body typed block allocators stay separate so the pointer type is the block type
@(private)
ensure_account :: proc(t: ^Tree, block: u32) -> bool {
	tables := ensure_tables(t, t.allocator)
	if tables == nil {
		return false
	}
	if sync.atomic_load(&tables.accounts[block]) != nil {
		return true
	}
	sync.guard(&t.mutex)
	if tables.accounts[block] != nil {
		return true
	}
	b, err := new(Account_Block, t.allocator)
	if err != nil {
		return false
	}
	sync.atomic_store(&tables.accounts[block], b)
	return true
}

//review:ignore duplicate-body typed block allocators stay separate so the pointer type is the block type
@(private)
ensure_rare :: proc(t: ^Tree, block: u32) -> bool {
	tables := ensure_tables(t, t.allocator)
	if tables == nil {
		return false
	}
	if sync.atomic_load(&tables.rares[block]) != nil {
		return true
	}
	sync.guard(&t.mutex)
	if tables.rares[block] != nil {
		return true
	}
	b, err := new(Rare_Block, t.allocator)
	if err != nil {
		return false
	}
	sync.atomic_store(&tables.rares[block], b)
	return true
}

/*
exact_frees is the quantity a report may write. ok is false unless the basis is
Exact, and then bytes may be 0. Charged and Unknown are not reported as 0.
*/
exact_frees :: proc(f: Freed) -> (bytes: u64, ok: bool) {
	if f.basis != .Exact {
		return 0, false
	}
	return f.bytes, true
}

/*
Delete_Line is the extra line beside one node's charged size.

has_frees is set only for Exact, and only when that quantity differs from
charged, so an exact 0 equal to a charged 0 is not "deleting frees 0". unknown
is the phrase for a known length that differs from the charge when the basis is
not Exact. An ordinary charged file whose length is unknown, or equal to the
charge, gets neither.
*/
Delete_Line :: struct {
	frees:     u64,
	has_frees: bool,
	unknown:   bool,
}

delete_line :: proc(t: ^Tree, index: u32, charged: u64) -> (line: Delete_Line) {
	f := freed_of(t, index)
	if f.basis == .Exact && f.bytes != charged {
		line.frees = f.bytes
		line.has_frees = true
		return
	}
	if f.basis == .Exact {
		return
	}
	a, ok := account_of(t, index)
	if ok && .Logical in a.known && a.logical != charged {
		line.unknown = true
	}
	return
}
