package leita_cli

import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../update"

UPDATE_ASSET :: "leita-test-asset"

// A release on disk and an executable. The sums are signed by key; the CLI
// passes that public half through, the way a build passes LEITA_UPDATE_KEY.
@(private = "file")
Release :: struct {
	root, dir, exe: string,
	priv:           ed25519.Private_Key,
	key:            [ed25519.PUBLIC_KEY_SIZE]byte,
}

@(private = "file")
sha256 :: proc(body: string) -> string {
	return string(
		hex.encode(
			hash.hash_string(.SHA256, body, context.temp_allocator),
			context.temp_allocator,
		),
	)
}

@(private = "file")
release_of :: proc(t: ^testing.T, running, published, version: string) -> (r: Release) {
	root, err := os.make_directory_temp("", "leita-update-cli-*", context.temp_allocator)
	testing.expect(t, err == nil)
	r.root = root
	r.dir = fmt.tprintf("%s/release", root)
	r.exe = fmt.tprintf("%s/bin/leita", root)
	testing.expect(t, os.make_directory_all(r.dir) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/bin", root)) == nil)
	testing.expect(t, os.write_entire_file(r.exe, transmute([]byte)running) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s", r.dir, UPDATE_ASSET),
			transmute([]byte)published,
		) ==
		nil,
	)
	testing.expect(t, ed25519.private_key_generate(&r.priv), "key generation")
	ed25519.private_key_public_bytes(&r.priv, r.key[:])
	ver := fmt.tprintf("%s\n", version)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/version.txt", r.dir), transmute([]byte)ver) == nil,
	)
	write_sums(t, &r, {{UPDATE_ASSET, sha256(published)}, {"version.txt", sha256(ver)}})
	return
}

@(private = "file")
Sum :: struct {
	name, hash: string,
}

@(private = "file")
write_sums :: proc(t: ^testing.T, r: ^Release, lines: []Sum) {
	b := strings.builder_make(context.temp_allocator)
	for line in lines {
		fmt.sbprintf(&b, "%s  %s\n", line.hash, line.name)
	}
	text := strings.to_string(b)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/sha256sums.txt", r.dir), transmute([]byte)text) ==
		nil,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&r.priv, transmute([]byte)text, sig[:])
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/sha256sums.txt.sig", r.dir), sig[:]) == nil,
	)
}

@(private = "file")
cfg_of :: proc(r: ^Release) -> update.Config {
	return update.Config {
		base = r.dir,
		version = "v1.0.0",
		asset = UPDATE_ASSET,
		exe = r.exe,
		user_agent = "leita/v1.0.0",
		public_key = r.key[:],
		hold_known = true,
	}
}

@(private = "file")
update_says :: proc(cfg: update.Config, args: ..string) -> (int, string) {
	b := strings.builder_make(context.temp_allocator)
	code := update_dispatch(cfg, args, strings.to_writer(&b))
	return code, strings.to_string(b)
}

@(private)
read_file :: proc(t: ^testing.T, path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, path)
	return string(data)
}

// --check exits 0 when this is the latest release's build, naming both versions.
@(test)
update_check_is_zero_when_current :: proc(t: ^testing.T) {
	r := release_of(t, "same build", "same build", "v1.0.0")
	defer os.remove_all(r.root)
	code, said := update_says(cfg_of(&r), "--check")
	testing.expect_value(t, code, EXIT_OK)
	for want in ([]string{"current    v1.0.0", "latest     v1.0.0", "this is the latest leita"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}
}

// --check exits 2 when the release has another build, and changes nothing.
@(test)
update_check_is_two_when_newer :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	code, said := update_says(cfg_of(&r), "--check")
	testing.expect_value(t, code, EXIT_NEWER)
	for want in ([]string{"current    v1.0.0", "latest     v1.1.0", "leita update installs it"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}
	testing.expect_value(t, read_file(t, r.exe), "old build")
}

// --check exits 1 when the release cannot be read, saying nothing on standard output.
@(test)
update_check_is_one_on_an_error :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	cfg := cfg_of(&r)
	cfg.base = fmt.tprintf("%s/nowhere", r.root)
	code, said := update_says(cfg, "--check")
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")
}

// leita update installs the newer build in place, keeps the old one beside it, and
// says what it did; a second run finds nothing to do.
@(test)
update_installs_the_newer_build :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	code, said := update_says(cfg_of(&r))
	testing.expect_value(t, code, EXIT_OK)
	for want in ([]string{"updated", "from v1.0.0 to v1.1.0, by the full build", "replaced", ".old", "run leita again"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}
	testing.expect_value(t, read_file(t, r.exe), "new build")
	testing.expect_value(t, read_file(t, fmt.tprintf("%s.old", r.exe)), "old build")

	code, said = update_says(cfg_of(&r))
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "is the latest release; nothing to do"), said)
}

// A download that does not match the hash the release publishes is not installed.
@(test)
update_refuses_a_hash_mismatch :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	write_sums(
		t,
		&r,
		{{UPDATE_ASSET, sha256("not the file")}, {"version.txt", sha256("v1.1.0\n")}},
	)
	code, said := update_says(cfg_of(&r))
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")
	testing.expect_value(t, read_file(t, r.exe), "old build")
	testing.expect(t, !os.exists(fmt.tprintf("%s.new", r.exe)), "no half-installed file")
}

// A development build, the kind these tests are, checks but is never replaced.
@(test)
update_never_replaces_a_development_build :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	cfg := cfg_of(&r)
	cfg.version = "dev"
	code, _ := update_says(cfg, "--check")
	testing.expect_value(t, code, EXIT_NEWER)
	code, _ = update_says(cfg)
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, read_file(t, r.exe), "old build")
}

// Anything but --check or nothing is a bad flag, and -h says what update does.
@(test)
update_takes_check_or_nothing :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	code, _ := update_says(cfg_of(&r), "--now")
	testing.expect_value(t, code, EXIT_ERROR)
	code, _ = update_says(cfg_of(&r), "--check", "extra")
	testing.expect_value(t, code, EXIT_ERROR)
	said: string
	code, said = update_says(cfg_of(&r), "-h")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect_value(t, said, UPDATE_USAGE)
	testing.expect_value(t, read_file(t, r.exe), "old build")
	testing.expect(
		t,
		is_subcommand([]string{"update"}),
		"update is a subcommand, so Leita runs it as leita does",
	)
}

// An unsigned manifest is an error, and the executable stays as it was.
@(test)
update_refuses_an_unsigned_manifest :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	testing.expect(t, os.remove(fmt.tprintf("%s/sha256sums.txt.sig", r.dir)) == nil)
	code, said := update_says(cfg_of(&r))
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")
	testing.expect_value(t, read_file(t, r.exe), "old build")

	bare := cfg_of(&r)
	bare.public_key = nil
	code, said = update_says(bare, "--check")
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")
}

// A retained Pro installation is not replaced by a release after its paid-through date.
@(test)
update_refuses_a_release_after_paid_through :: proc(t: ^testing.T) {
	r := release_of(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(r.root)
	stamp := "2026-10-19T12:00:01Z\n"
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/released.txt", r.dir), transmute([]byte)stamp) == nil,
	)
	write_sums(
		t,
		&r,
		{
			{UPDATE_ASSET, sha256("new build")},
			{"version.txt", sha256("v1.1.0\n")},
			{"released.txt", sha256(stamp)},
		},
	)
	cfg := cfg_of(&r)
	cfg.hold = {
		retained     = true,
		paid_through = "2026-10-19T12:00:00Z",
	}
	code, said := update_says(cfg, "--check")
	testing.expect_value(t, code, EXIT_NEWER)
	testing.expect(t, strings.contains(said, "v1.1.0"), said)
	code, said = update_says(cfg)
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")
	testing.expect_value(t, read_file(t, r.exe), "old build")
}
