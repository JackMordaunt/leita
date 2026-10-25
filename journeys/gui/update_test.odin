package journeys_gui

import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:testing"

import "jm:ui"

import "../../update"

/*
publish writes a release of build, called version, into dir as the release page
holds one: the window's build for this platform, version.txt, their SHA-256 sums,
and the sums signed with priv.
*/
publish :: proc(t: ^testing.T, dir, build, version: string, priv: ^ed25519.Private_Key) {
	name := update.asset(.Window)
	testing.expect(t, name != "", "a release is built for this platform")

	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the release")

	sum :: proc(s: string) -> string {
		return string(
			hex.encode(
				hash.hash_string(.SHA256, s, context.temp_allocator),
				context.temp_allocator,
			),
		)
	}
	sums := fmt.tprintf("%s  %s\n%s  version.txt\n", sum(build), name, sum(version))

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", dir, name), build) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/version.txt", dir), version) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sha256sums.txt", dir), sums) == nil)

	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(priv, transmute([]byte)sums, sig[:])
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/sha256sums.txt.sig", dir), sig[:]) == nil,
	)
}

/*
Story: a person updates Leita when they choose to. About checks the release
page only when asked; a newer signed release is named, Update installs it over
this copy, and the window says to restart. Asked again, it is the latest. A
release signed by anyone else is refused and replaces nothing.
*/
@(test)
an_update_is_found_and_installed_when_asked :: proc(t: ^testing.T) {
	budget(t, 120)
	root := real_folder(t, "update")
	defer os.remove_all(root)

	page := real_folder(t, "release")
	defer os.remove_all(page)

	release := within(page, "latest")
	installed := within(root, "leita")
	write_file(t, installed, 16)
	context.random_generator = crypto.random_generator()
	key: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_generate(&key), "the release key")
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&key, pub[:])
	publish(t, release, "the newer window", "v9.9.9\n", &key)

	w: Window
	open(
		&w,
		t,
		"update",
		REAL,
		path = root,
		release_base = release,
		update_key = pub[:],
		update_exe = installed,
	)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))
	testing.expect(t, click(&w, "Settings"))
	frames(&w, 10)
	testing.expect(t, click_top(&w, "About Leita"))
	frames(&w, 20)
	testing.expectf(
		t,
		settle(&w, "Check for updates", seconds = 10),
		"About offers the check:\n%s",
		show(&w),
	)
	testing.expect(t, click_top(&w, "Check for updates"))
	testing.expectf(
		t,
		settle(&w, "Version v9.9.9 of Leita is available.", seconds = 30),
		"the newer release is named:\n%s",
		show(&w),
	)
	keep(&w, "available")
	testing.expect(t, click_top(&w, "Update"))
	testing.expectf(
		t,
		settle(&w, "Updated. Restart Leita to use the new version.", seconds = 30),
		"it installs and says to restart:\n%s",
		show(&w),
	)
	keep(&w, "updated")
	body, _ := os.read_entire_file(installed, context.temp_allocator)
	testing.expect_value(t, string(body), "the newer window")

	// Asked again, the copy is the release's.
	testing.expect(t, click_top(&w, "Check for updates"))
	testing.expectf(
		t,
		settle(&w, "This is the latest version of Leita.", seconds = 30),
		"this copy is the latest:\n%s",
		show(&w),
	)

	// A newer release signed by another key is refused, and nothing replaced.
	other: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_generate(&other), "a forger's key")
	publish(t, release, "a forged window", "v9.9.10\n", &other)
	testing.expect(t, click_top(&w, "Check for updates"))
	testing.expectf(
		t,
		settle(
			&w,
			"The update failed: the signature of sha256sums.txt does not verify",
			seconds = 30,
		),
		"a forged release is refused:\n%s",
		show(&w),
	)
	keep(&w, "forged")
	testing.expect(t, !ui.probe_tagged(&w.p, "Update"), "no Update is offered")
	body, _ = os.read_entire_file(installed, context.temp_allocator)
	testing.expect_value(t, string(body), "the newer window")
}
