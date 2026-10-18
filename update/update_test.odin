package update

import "core:bytes"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "jm:http/loopback"
import "jm:path"
import "jm:selfupdate"
import "jm:zstd"

// The tests run the package under the runner's tracking allocator on purpose:
// a leak in it fails the test. The helpers' scratch goes on the temp allocator.

ASSET :: "leita-test-asset"

// Fixture is a release on disk and an executable to update.
Fixture :: struct {
	root:    string,
	release: string,
	exe:     string,
	priv:    ed25519.Private_Key,
	key:     [ed25519.PUBLIC_KEY_SIZE]byte,
}

fixture :: proc(t: ^testing.T, running, published, version: string) -> (f: Fixture) {
	ta := context.temp_allocator
	root, err := path.temp_dir("leita-update-", ta)
	testing.expect_value(t, err, nil)
	f.root = root
	f.release = path.join(root, "release", allocator = ta)
	testing.expect_value(t, path.mkdirs(f.release), nil)
	f.exe = path.join(root, "bin", "leita", allocator = ta)
	testing.expect_value(t, path.write(f.exe, running), nil)
	testing.expect(t, ed25519.private_key_generate(&f.priv), "key generation")
	ed25519.private_key_public_bytes(&f.priv, f.key[:])
	publish(t, &f, published, version)
	return
}

// publish writes the asset, version.txt and sha256sums.txt. Each sums line is
// a hex digest, two spaces, the file name and a newline, then a signature the
// fixture's key makes.
publish :: proc(t: ^testing.T, f: ^Fixture, body, version: string) {
	ta := context.temp_allocator
	testing.expect_value(t, path.write(path.join(f.release, ASSET, allocator = ta), body), nil)
	testing.expect_value(t, path.write(path.join(f.release, "version.txt", allocator = ta), strings.concatenate({version, "\n"}, ta)), nil)
	write_sums(t, f, {{ASSET, sha256(body)}})
}

Sum :: struct {
	name, hash: string,
}

write_sums :: proc(t: ^testing.T, f: ^Fixture, lines: []Sum) {
	ta := context.temp_allocator
	b := strings.builder_make(ta)
	for l in lines {
		strings.write_string(&b, l.hash)
		strings.write_string(&b, "  ")
		strings.write_string(&b, l.name)
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	testing.expect_value(t, path.write(path.join(f.release, "sha256sums.txt", allocator = ta), text), nil)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&f.priv, transmute([]byte)text, sig[:])
	testing.expect_value(t, path.write(path.join(f.release, "sha256sums.txt.sig", allocator = ta), string(sig[:])), nil)
}

sha256 :: proc(body: string) -> string {
	return string(hex.encode(hash.hash_string(.SHA256, body, context.temp_allocator), context.temp_allocator))
}

config :: proc(f: Fixture, version := "v1.0.0") -> Config {
	return Config{base = f.release, version = version, asset = ASSET, exe = f.exe, user_agent = "leita/" + "test"}
}

read :: proc(p: string) -> string {
	s, _ := path.read(p, context.temp_allocator)
	return s
}

exists :: proc(p: string) -> bool {
	return os.exists(p)
}

@(test)
the_same_build_is_current :: proc(t: ^testing.T) {
	f := fixture(t, "same build", "same build", "v1.0.0")
	defer os.remove_all(f.root)
	r := check(config(f))
	testing.expect_value(t, r.outcome, Outcome.Current)
	testing.expect_value(t, latest(&r), "v1.0.0")
	r = apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Current)
	testing.expect_value(t, read(f.exe), "same build")
}

@(test)
the_release_naming_this_version_is_current_whatever_the_bytes :: proc(t: ^testing.T) {
	f := fixture(t, "built here", "built by ci", "v1.0.0")
	defer os.remove_all(f.root)
	r := check(config(f))
	testing.expect_value(t, r.outcome, Outcome.Current)
	r = apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Current)
	testing.expect_value(t, read(f.exe), "built here")
}

@(test)
a_newer_release_is_available_and_check_changes_nothing :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	r := check(config(f))
	testing.expect_value(t, r.outcome, Outcome.Available)
	testing.expect_value(t, latest(&r), "v1.1.0")
	testing.expect_value(t, message(&r), "v1.1.0 is available")
	testing.expect_value(t, read(f.exe), "old build")
	testing.expect(t, !exists(strings.concatenate({f.exe, ".new"}, context.temp_allocator)), "no temp file")
}

@(test)
a_development_build_checks_but_never_applies :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	testing.expect_value(t, check(config(f, "dev")).outcome, Outcome.Available)
	r := apply(config(f, "dev"))
	testing.expect_value(t, r.outcome, Outcome.Refused)
	testing.expect_value(t, r.reason, Reason.Dev_Build)
	testing.expect_value(t, read(f.exe), "old build")
}

@(test)
apply_replaces_the_executable_and_keeps_the_old_one :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	old := strings.concatenate({f.exe, ".old"}, context.temp_allocator)
	r := apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, r.via, selfupdate.Via.Full)
	testing.expect_value(t, message(&r), "updated via full download")
	testing.expect_value(t, read(f.exe), "new build")
	testing.expect_value(t, read(old), "old build")
	testing.expect(t, !exists(strings.concatenate({f.exe, ".new"}, context.temp_allocator)), "no temp file")

	// The next update finds itself current, and clears the old copy once it
	// has one to replace.
	testing.expect_value(t, apply(config(f)).outcome, Outcome.Current)
}

@(test)
a_download_that_does_not_match_its_hash_is_not_installed :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	// The sums promise bytes the asset does not hold: a corrupted or swapped file.
	write_sums(t, &f, {{ASSET, sha256("what the sums promise")}})
	r := apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Failed)
	testing.expect_value(t, r.reason, Reason.Bad_Download)
	testing.expect_value(t, read(f.exe), "old build")
	testing.expect(t, !exists(strings.concatenate({f.exe, ".new"}, context.temp_allocator)), "no temp file")
	testing.expect(t, !exists(strings.concatenate({f.exe, ".dl"}, context.temp_allocator)), "no download left")
}

@(test)
an_asset_the_release_lacks_fails :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	write_sums(t, &f, {{"leita-other", sha256("x")}})
	r := check(config(f))
	testing.expect_value(t, r.outcome, Outcome.Failed)
	testing.expect_value(t, r.reason, Reason.Not_Published)
	r = check(Config{base = path.join(f.root, "nowhere", allocator = context.temp_allocator), asset = ASSET, exe = f.exe})
	testing.expect_value(t, r.outcome, Outcome.Failed)
	testing.expect_value(t, r.reason, Reason.Not_Published)
}

@(test)
the_smaller_routes_are_taken_when_the_sums_list_them :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	older := string(noise(200_000, 1))
	newer := strings.clone(older, ta)
	newer = strings.concatenate({newer[:100_000], string(noise(2000, 2)), newer[102_000:]}, ta)
	f := fixture(t, older, newer, "v1.1.0")
	defer os.remove_all(f.root)

	compressed := compress(t, newer, "")
	zst := strings.concatenate({ASSET, ".zst"}, ta)
	testing.expect_value(t, path.write(path.join(f.release, zst, allocator = ta), compressed), nil)
	write_sums(t, &f, {{ASSET, sha256(newer)}, {zst, sha256(compressed)}})
	r := apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, r.via, selfupdate.Via.Compressed)
	testing.expect(t, read(f.exe) == newer, "the compressed asset installs the new build")

	// The patch from the build that runs is cheaper still.
	testing.expect_value(t, path.write(f.exe, older), nil)
	patch := compress(t, newer, older)
	name := strings.concatenate({ASSET, ".", sha256(older), ".patch"}, ta)
	testing.expect_value(t, path.write(path.join(f.release, name, allocator = ta), patch), nil)
	write_sums(t, &f, {{ASSET, sha256(newer)}, {zst, sha256(compressed)}, {name, sha256(patch)}})
	r = apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, r.via, selfupdate.Via.Patch)
	testing.expect(t, read(f.exe) == newer, "the patch installs the new build")

	// A patch that does not match its published hash falls through to the next route.
	testing.expect_value(t, path.write(f.exe, older), nil)
	testing.expect_value(t, path.write(path.join(f.release, name, allocator = ta), "garbage"), nil)
	r = apply(config(f))
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, r.via, selfupdate.Via.Compressed)
}

@(test)
a_signed_release_must_verify_when_a_key_is_set :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	cfg := config(f)
	cfg.public_key = f.key[:]
	testing.expect_value(t, check(cfg).outcome, Outcome.Available)

	// The sums changed after they were signed.
	ta := context.temp_allocator
	testing.expect_value(t, path.write(path.join(f.release, "sha256sums.txt", allocator = ta), strings.concatenate({sha256("evil"), "  ", ASSET, "\n"}, ta)), nil)
	r := apply(cfg)
	testing.expect_value(t, r.outcome, Outcome.Failed)
	testing.expect_value(t, r.reason, Reason.Bad_Signature)
	testing.expect_value(t, read(f.exe), "old build")

	// No signature at all fails too, rather than falling back to the hashes.
	os.remove(path.join(f.release, "sha256sums.txt.sig", allocator = ta))
	testing.expect_value(t, check(cfg).outcome, Outcome.Failed)
	// With no key configured, the hashes alone decide.
	write_sums(t, &f, {{ASSET, sha256("new build")}})
	os.remove(path.join(f.release, "sha256sums.txt.sig", allocator = ta))
	testing.expect_value(t, check(config(f)).outcome, Outcome.Available)
}

@(test)
a_copy_leita_cannot_replace_is_refused_with_where_to_download :: proc(t: ^testing.T) {
	testing.expect_value(t, install_of("/home/a/bin/leita"), Install.Loose)
	testing.expect_value(t, install_of("/usr/local/bin/leita"), Install.Loose)
	testing.expect_value(t, install_of("/Users/a/Applications/Leita.app/Contents/Helpers/leita"), Install.Bundle)
	testing.expect_value(t, install_of("/Applications/Leita.app/Contents/MacOS/Leita"), Install.Bundle)
	testing.expect_value(t, install_of("/usr/bin/leita"), Install.Package)
	testing.expect_value(t, install_of("/usr/libexec/leita/leita"), Install.Package)
	testing.expect_value(t, install_of("/opt/homebrew/Cellar/leita/1/bin/leita"), Install.Package)
	testing.expect_value(t, install_of("/tmp/.mount_LeitaXYZ/usr/bin/Leita"), Install.App_Image)
	testing.expect_value(t, install_of("/home/a/Leita.AppImage", app_image = true), Install.App_Image)
	testing.expect_value(t, install_of("C:\\Program Files\\Leita\\leita.exe"), Install.Installer)
	testing.expect_value(t, install_of("C:\\Users\\a\\bin\\leita.exe"), Install.Loose)

	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	// A link, as a checkout installs it.
	target := path.join(f.root, "target", allocator = context.temp_allocator)
	testing.expect_value(t, path.write(target, "old build"), nil)
	link := path.join(f.root, "link", allocator = context.temp_allocator)
	if os.symlink(target, link) == nil {
		cfg := config(f)
		cfg.exe = link
		r := apply(cfg)
		testing.expect_value(t, r.outcome, Outcome.Refused)
		testing.expect_value(t, r.reason, Reason.Link)
		testing.expect(t, strings.contains(message(&r), RELEASE_PAGE), "it says where to download")
		testing.expect_value(t, read(target), "old build")
	}
	r: Result
	finish(&r, .Refused, .Bundle, "%s", refusal_text(.Bundle, "v1.1.0"))
	testing.expect(t, strings.contains(message(&r), "Leita.app"), "the bundle is named")
	testing.expect(t, strings.contains(message(&r), "v1.1.0"), "the version is named")
	testing.expect(t, not_replaceable(.Bundle) && !not_replaceable(.Unreachable))
}

// Served over HTTP, each request carries User-Agent leita/<version> and
// nothing that names the person: the request line and a few fixed headers.
@(test)
requests_name_leita_and_the_version_only :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)

	Seen :: struct {
		mutex: sync.Mutex,
		heads: [dynamic]string,
		dir:   string,
	}
	seen := Seen {
		heads = make([dynamic]string, context.allocator),
		dir   = f.release,
	}
	defer {
		for h in seen.heads {
			delete(h)
		}
		delete(seen.heads)
	}
	srv, ok := loopback.start(
		proc(conn: ^loopback.Conn, req: loopback.Request) {
			s := (^Seen)(conn.server.user)
			sync.mutex_guard(&s.mutex)
			append(&s.heads, strings.clone(req.head))
			body, err := os.read_entire_file(path.join(s.dir, req.path[1:], allocator = context.temp_allocator), context.temp_allocator)
			if err != nil {
				loopback.send(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
				return
			}
			loopback.send(conn, strings.concatenate({"HTTP/1.1 200 OK\r\nContent-Length: ", itoa(len(body)), "\r\n\r\n"}, context.temp_allocator))
			loopback.send(conn, string(body))
		},
		&seen,
		context.allocator,
	)
	testing.expect(t, ok, "the server starts")
	defer loopback.stop(srv)

	cfg := config(f)
	cfg.base = strings.trim_suffix(loopback.url(srv, "/"), "/")
	cfg.user_agent = "leita/v1.0.0"
	r := check(cfg)
	testing.expect_value(t, r.outcome, Outcome.Available)
	testing.expect_value(t, latest(&r), "v1.1.0")
	r = apply(cfg)
	testing.expect_value(t, r.outcome, Outcome.Applied)
	testing.expect_value(t, read(f.exe), "new build")

	testing.expect(t, len(seen.heads) >= 3, "sums, version and the asset were asked for")
	for h in seen.heads {
		testing.expect(t, strings.has_prefix(h, "GET /"), "only GET")
		testing.expectf(t, strings.contains(h, "User-Agent: leita/v1.0.0\r\n"), "the user agent names leita and its version: %q", h)
		testing.expect(t, !strings.contains(strings.to_lower(h, context.temp_allocator), "cookie"), "no cookie")
		testing.expect(t, !strings.contains(strings.to_lower(h, context.temp_allocator), "authorization"), "no credentials")
	}
}

@(test)
an_unreachable_host_fails_with_a_reason :: proc(t: ^testing.T) {
	f := fixture(t, "old build", "new build", "v1.1.0")
	defer os.remove_all(f.root)
	cfg := config(f)
	cfg.base = "http://127.0.0.1:1"
	r := check(cfg)
	testing.expect_value(t, r.outcome, Outcome.Failed)
	testing.expect(t, r.reason == .Unreachable || r.reason == .No_Library, "unreachable, or no libcurl to try")
	testing.expect_value(t, read(f.exe), "old build")
}

// noise fills n bytes from seed, so the payload is not a repeated run.
noise :: proc(n: int, seed: u64) -> []byte {
	b := make([]byte, n, context.temp_allocator)
	x := seed
	for &c in b {
		x = x * 6364136223846793005 + 1442695040888963407
		c = byte(x >> 56)
	}
	return b
}

// compress is body as a zstd file, a patch from prefix when one is given.
compress :: proc(t: ^testing.T, body, prefix: string) -> string {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, 0, context.temp_allocator)
	w := bytes.buffer_to_stream(&buf)
	if prefix != "" {
		testing.expect_value(t, zstd.diff(w, transmute([]byte)prefix, transmute([]byte)body, allocator = context.temp_allocator), nil)
	} else {
		out := make([]byte, zstd.compress_bound(len(body)), context.temp_allocator)
		packed, err := zstd.compress(out, transmute([]byte)body)
		testing.expect_value(t, err, nil)
		return string(packed)
	}
	return string(bytes.buffer_to_bytes(&buf))
}

itoa :: proc(n: int) -> string {
	return strings.clone(fmt.tprint(n), context.temp_allocator)
}
