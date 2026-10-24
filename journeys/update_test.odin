package journeys

import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// SEED is the private half of the update key the journeys' binary is built with
// (journey_update_key in the justfile). It is in the open on purpose: nothing it
// signs is a release.
SEED :: [32]byte {
	1,
	2,
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
	16,
	17,
	18,
	19,
	20,
	21,
	22,
	23,
	24,
	25,
	26,
	27,
	28,
	29,
	30,
	31,
	32,
}

// asset is the release file the command line of this platform updates from.
asset :: proc() -> string {
	when ODIN_OS == .Windows {
		return "leita-windows-amd64.exe"
	} else when ODIN_OS == .Darwin {
		return "leita-darwin-universal"
	} else when ODIN_ARCH == .arm64 {
		return "leita-linux-arm64"
	} else {
		return "leita-linux-amd64"
	}
}

// sha256 is the hex digest of body.
sha256 :: proc(body: string) -> string {
	return string(
		hex.encode(
			hash.hash_string(.SHA256, body, context.temp_allocator),
			context.temp_allocator,
		),
	)
}

// Release is a folder laid out as a release page is: the build, its version, and
// the list of their digests with the signature of it.
Release :: struct {
	dir: string,
}

// publish lays a release of the build's bytes as version into a new folder in h,
// signed with SEED.
publish :: proc(t: ^testing.T, h: Home, build, version: string) -> Release {
	dir := file_in(h, "release")
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the release folder")
	ver := strings.concatenate({version, "\n"}, context.temp_allocator)
	put(t, dir, asset(), build)
	put(t, dir, "version.txt", ver)
	sums := fmt.tprintf("%s  %s\n%s  version.txt\n", sha256(build), asset(), sha256(ver))
	put(t, dir, "sha256sums.txt", sums)

	seed := SEED
	key: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&key, seed[:]), "could not take the seed")
	signature: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&key, transmute([]byte)sums, signature[:])
	put(t, dir, "sha256sums.txt.sig", string(signature[:]))
	return {dir = dir}
}

// put writes body as name in dir.
put :: proc(t: ^testing.T, dir, name, body: string) {
	testing.expectf(
		t,
		os.write_entire_file(fmt.tprintf("%s/%s", dir, name), body) == nil,
		"could not write %s",
		name,
	)
}

// release_env is LEITA_RELEASE_BASE=where_ as the extra environment of a run.
release_env :: proc(where_: string) -> []string {
	env := make([]string, 1, context.temp_allocator)
	env[0] = strings.concatenate({"LEITA_RELEASE_BASE=", where_}, context.temp_allocator)
	return env
}

// A person asks which release is out. A newer one exits with 2 for a script to
// read; the build that is already the release exits with 0.
@(test)
update_check_says_whether_a_newer_release_is_out :: proc(t: ^testing.T) {
	h := home(t, "update")
	defer leave(h)

	rel := publish(t, h, "a build that is not this one", "v9.9.9")
	r := run(t, h, -1, "update", "--check", extra = release_env(rel.dir))
	expect_code(t, r, 2)
	testing.expect(t, strings.contains(r.out, "latest     v9.9.9"), r.out)
	testing.expect(t, strings.contains(r.out, "a newer leita is out"), r.out)

	// This very build, published, is the latest whatever it calls itself.
	own, err := os.read_entire_file(binary(), context.temp_allocator)
	testing.expect(t, err == nil, "could not read the binary")
	rel = publish(t, h, string(own), "v1.0.0")
	r = run(t, h, -1, "update", "--check", extra = release_env(rel.dir))
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "this is the latest leita"), r.out)
}

// A release that cannot be shown to be the maker's is not believed, and nothing
// is installed.
@(test)
update_check_refuses_a_release_that_does_not_verify :: proc(t: ^testing.T) {
	h := home(t, "update_forged")
	defer leave(h)

	rel := publish(t, h, "a build that is not this one", "v9.9.9")
	// The digests change after they were signed.
	put(t, rel.dir, "sha256sums.txt", fmt.tprintf("%s  %s\n", sha256("another"), asset()))
	r := run(t, h, -1, "update", "--check", extra = release_env(rel.dir))
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.err, "does not verify"), r.err)

	os.remove(fmt.tprintf("%s/sha256sums.txt.sig", rel.dir))
	r = run(t, h, -1, "update", "--check", extra = release_env(rel.dir))
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.err, "no signature"), r.err)

	r = run(t, h, -1, "update", "--check", extra = release_env(file_in(h, "nowhere")))
	expect_code(t, r, 1)
}

// Leita asks the release page only when told to: scanning, reports and
// listing never reach it, and asking sends a GET naming leita and nothing else.
@(test)
update_asks_the_release_page_only_when_run :: proc(t: ^testing.T) {
	h := home(t, "update_quiet")
	defer leave(h)

	rel := publish(t, h, "a build that is not this one", "v9.9.9")
	page := start_receiver(t, dir = rel.dir)
	defer stop_receiver(page)

	where_ := release_env(strings.trim_suffix(address(page), "/"))

	r := run(t, h, 0, "/Users/alex", extra = where_)
	expect_code(t, r, 0)
	r = run(t, h, 0, "--report", "-", "--format", "json", "/Users/alex", extra = where_)
	expect_code(t, r, 0)
	r = run(t, h, 0, "licence", extra = where_)
	r = run(t, h, -1, "monitor", "list", extra = where_)
	r = run(t, h, 0, "history", extra = where_)
	testing.expect_value(t, len(requests(page)), 0)

	r = run(t, h, -1, "update", "--check", extra = where_)
	expect_code(t, r, 2)
	asked := requests(page)
	testing.expect(t, len(asked) >= 3, "the sums, their signature and the version were asked for")
	for q in asked {
		testing.expectf(t, strings.has_prefix(q.head, "GET /"), "only GET: %s", q.head)
		testing.expectf(t, strings.contains(q.head, "User-Agent: leita/"), "named: %s", q.head)
		lower := strings.to_lower(q.head, context.temp_allocator)
		testing.expectf(t, !strings.contains(lower, "cookie"), "no cookie: %s", q.head)
		testing.expectf(t, !strings.contains(lower, "authorization"), "no credentials: %s", q.head)
	}
}
