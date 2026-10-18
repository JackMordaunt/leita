/*
Package update finds and installs a newer leita on request. Nothing here runs
on its own: `leita update` and the window's About call it, and a person asks
each time. Neither checks at start-up, on a timer or in the background, and
the only request leita makes is the download itself: GET, for a file under
RELEASE_BASE, with the User-Agent leita/<version> and nothing else that names
the person, the machine or the disks.

A release is the files release.yml publishes, served under one base path as
jm:selfupdate lays them out: each binary alone under a name no release changes
(leita-linux-amd64, leita-window-windows-amd64.exe), its .zst and a patch from
each of the last few releases, sha256sums.txt over all of them, and version.txt.
An update exists when the published hash of this binary's asset differs from
the hash of the running executable, unless version.txt names the version
already running; no version is compared as greater or less. It is installed by
the cheapest route the sums list: the patch from this build, then the
compressed asset, then the asset itself. A download is checked against its
published hash before anything reads it, and what it decodes to against the
asset's; one that fails falls through to the next route.

Why not selfupdate.run: run (jm/selfupdate/selfupdate.odin) fetches and verifies
sha256sums.txt.sig under an embedded key, and neither exists yet (card 547's
signing step), and fetch there sends jm:http's own User-Agent. This
package uses selfupdate's pieces, the hashes, the decoder and the swap, and
fetches itself. SIGNING_KEY is the hook: once the release signs sha256sums.txt
with the Ed25519 key whose public half is set there, the manifest is trusted
only when sha256sums.txt.sig verifies, and an update fails without it. Until
then the hashes prove a download arrived whole from the host, not who put it
there.

The executable is replaced the way selfupdate does: the running file is renamed
to <exe>.old and the new one moved in (selfupdate.swap, whose comment holds why:
a running executable can be renamed on every platform but overwritten not on
Windows), so there the old file stays beside the new until the next update
removes it. Only
a copy leita can replace is replaced: a development build, a link, a package's
file, an AppImage, an installer's Program Files copy, and anything inside
Leita.app are refused, with the page to download from: a signed bundle's
signature covers every file in its Contents (Apple's Code Signing Guide), so
a file replaced inside it fails codesign --verify. The window and the command
line inside the bundle are replaced together, by the dmg.
*/
package update

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:http"
import "jm:selfupdate"

// RELEASE_BASE is where releases are served: the latest GitHub release's files
// under names no release changes. LEITA_RELEASE_BASE overrides it, with a
// directory (a base without "://") serving the same files from disk.
RELEASE_BASE :: "https://github.com/jackmordaunt/leita/releases/latest/download"

// RELEASE_PAGE is where a person downloads a release by hand: the dmg, the
// installer, the packages.
RELEASE_PAGE :: "https://github.com/jackmordaunt/leita/releases/latest"

// BASE_ENV names the variable that replaces RELEASE_BASE.
BASE_ENV :: "LEITA_RELEASE_BASE"

/*
SIGNING_KEY is the Ed25519 public key, 64 hex characters, that signs
sha256sums.txt in the release workflow. Empty until card 547 adds the signing
step and its secret: set it, and every check and update requires a valid
sha256sums.txt.sig (and tests/sign it with the key they make). HOOK: this is
the one place to turn signature checking on.
*/
SIGNING_KEY :: ""

// SUMS_CAP is the most of sha256sums.txt read; a larger file fails.
SUMS_CAP :: 64 * 1024

// DEFAULT_TIMEOUT bounds each download.
DEFAULT_TIMEOUT :: 60 * time.Second

// Binary is which of the release's single binaries this process is.
Binary :: enum {
	Command_Line,
	Window,
}

// asset is the file name of binary in a release for this platform, "" where
// the release has none: leita-linux-amd64, leita-window-windows-amd64.exe,
// leita-darwin-universal.
asset :: proc(b: Binary) -> string {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		return "leita-linux-amd64" if b == .Command_Line else "leita-window-linux-amd64"
	} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
		return "leita-linux-arm64" if b == .Command_Line else "leita-window-linux-arm64"
	} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
		return "leita-windows-amd64.exe" if b == .Command_Line else "leita-window-windows-amd64.exe"
	} else when ODIN_OS == .Darwin {
		return "leita-darwin-universal" if b == .Command_Line else "leita-window-darwin-universal"
	} else {
		return ""
	}
}

// Install is how the running copy came to be there, which decides whether it
// can be replaced in place.
Install :: enum {
	// A file a person put there: replaced in place.
	Loose,
	// Inside Leita.app, whose signature seals it.
	Bundle,
	// A package manager's file, or a Nix or Homebrew one.
	Package,
	// Inside an AppImage: its runtime mounts the image, so there is no file to replace.
	App_Image,
	// The installer's copy under Program Files.
	Installer,
}

/*
install_of says how the executable at exe was installed. app_image is whether
the AppImage runtime's APPIMAGE variable is set; the path alone gives away
the rest.
*/
install_of :: proc(exe: string, app_image := false) -> Install {
	p, _ := strings.replace_all(exe, "\\", "/", context.temp_allocator)
	switch {
	case strings.contains(p, ".app/Contents/"):
		return .Bundle
	case app_image || strings.contains(p, "/.mount_"):
		return .App_Image
	case strings.contains(strings.to_lower(p, context.temp_allocator), "/program files"):
		return .Installer
	case strings.has_prefix(p, "/usr/") && !strings.has_prefix(p, "/usr/local/"),
	     strings.has_prefix(p, "/opt/homebrew/"),
	     strings.contains(p, "/Cellar/"),
	     strings.has_prefix(p, "/nix/store/"),
	     strings.has_prefix(p, "/snap/"):
		return .Package
	}
	return .Loose
}

// Config says what to check against and what to replace.
Config :: struct {
	// Where the release's files are served, without a trailing slash; a value
	// without "://" is a directory. "" means BASE_ENV, else RELEASE_BASE.
	base:       string,
	// This build's version; "dev" or "" is a development build, which is
	// checked but never replaced.
	version:    string,
	// This build's file name in the release (asset).
	asset:      string,
	// The executable to check and replace. "" means this process's own.
	exe:        string,
	// The User-Agent of each request: leita/<version>.
	user_agent: string,
	// 32 raw bytes of the key sha256sums.txt.sig must verify under; nil means
	// SIGNING_KEY, and when that is empty no signature is asked for.
	public_key: []byte,
	// Whole-request timeout for each download. 0 means DEFAULT_TIMEOUT.
	timeout:    time.Duration,
}

// Outcome is how a check or an update ended.
Outcome :: enum {
	// This build is the release's.
	Current,
	// The release has another build; check stops here.
	Available,
	// The executable was replaced.
	Applied,
	// Another build exists, or may, and this copy is not one to replace; reason says why.
	Refused,
	Failed,
}

// Reason is why an outcome is Refused or Failed, for a caller that words it.
Reason :: enum {
	None,
	Dev_Build,
	Link,
	Bundle,
	Package,
	App_Image,
	Installer,
	// No release is built for this platform.
	Unsupported,
	// libcurl is not on this system (a Linux build opens it at run time).
	No_Library,
	Unreachable,
	// The release does not hold this asset, or any release is published.
	Not_Published,
	Bad_Signature,
	// The download did not match its published hash or did not decode.
	Bad_Download,
	Cannot_Replace,
}

// Result is returned by value; message and latest read its inline buffers.
Result :: struct {
	outcome:     Outcome,
	reason:      Reason,
	// The route an Applied update took.
	via:         selfupdate.Via,
	message_buf: [384]byte,
	message_len: int,
	latest_buf:  [selfupdate.VERSION_CAP]byte,
	latest_len:  int,
}

// message says what happened, in English, for the command line.
message :: proc(r: ^Result) -> string {
	return string(r.message_buf[:r.message_len])
}

// latest is the release's version from version.txt, "" when it was not read.
latest :: proc(r: ^Result) -> string {
	return string(r.latest_buf[:r.latest_len])
}

// not_replaceable says whether reason is that this copy is not one to replace,
// as opposed to a failure: the caller points to RELEASE_PAGE.
not_replaceable :: proc(reason: Reason) -> bool {
	#partial switch reason {
	case .Link, .Bundle, .Package, .App_Image, .Installer:
		return true
	}
	return false
}

@(private)
finish :: proc(r: ^Result, outcome: Outcome, reason: Reason, format: string, args: ..any) -> Result {
	r.outcome, r.reason = outcome, reason
	r.message_len = len(fmt.bprintf(r.message_buf[:], format, ..args))
	return r^
}

// default_config is the configuration of this process: b's asset, this build's
// version, the release's base unless BASE_ENV names another.
default_config :: proc(b: Binary, version: string) -> Config {
	base := os.get_env(BASE_ENV, context.temp_allocator)
	return Config {
		base = base if base != "" else RELEASE_BASE,
		version = version,
		asset = asset(b),
		user_agent = strings.concatenate({"leita/", version}, context.temp_allocator),
	}
}

// is_development says whether version marks a build that is not a release's.
is_development :: proc(version: string) -> bool {
	return version == "" || version == "dev"
}

/*
check asks the release what it holds and compares it with the running
executable, changing nothing. The outcome is Current, Available (latest says
which version), or Failed.
*/
check :: proc(cfg: Config) -> (r: Result) {
	inspect(cfg, &r)
	return r
}

/*
apply installs the release's build over the running executable when it
differs: Applied, Current when there is nothing to do, Refused for a copy that
is not to be replaced (the message says where to download), or Failed. It is
the caller's to restart into the new build.
*/
apply :: proc(cfg: Config) -> (r: Result) {
	if is_development(cfg.version) {
		return finish(&r, .Refused, .Dev_Build, "this is a development build, not a release; update replaces releases only")
	}
	rel, ok := inspect(cfg, &r)
	if !ok || r.outcome != .Available {
		return r
	}
	if why := install_reason(rel.exe); why != .None {
		return finish(&r, .Refused, why, "%s", refusal_text(why, latest(&r)))
	}

	old_buf, fresh_buf: [selfupdate.PATH_CAP]byte
	old := fmt.bprintf(old_buf[:], "%s.old", rel.exe)
	fresh := fmt.bprintf(fresh_buf[:], "%s.new", rel.exe)
	// swap clears the copy an earlier update left, which on Windows the run
	// that replaced it may still have held open.
	route := obtain(cfg, rel, fresh)
	if !route.ok {
		return finish(&r, .Failed, route.reason, "cannot download %s: %s", cfg.asset, route.note)
	}
	sr: selfupdate.Result
	if !selfupdate.swap(rel.exe, old, fresh, &sr) {
		os.remove(fresh)
		return finish(&r, .Failed, .Cannot_Replace, "%s", selfupdate.message(&sr))
	}
	r.via = route.via
	return finish(&r, .Applied, .None, "updated via %s", selfupdate.VIA_NAMES[route.via])
}

// why_not is why cfg's executable is not to be replaced in place, Dev_Build or
// an install_reason, .None when it is: what a window asks to choose between
// installing the update and sending a person to RELEASE_PAGE.
why_not :: proc(cfg: Config) -> Reason {
	if is_development(cfg.version) {
		return .Dev_Build
	}
	exe := cfg.exe
	if exe == "" {
		p, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			return .Cannot_Replace
		}
		exe = p
	}
	return install_reason(exe)
}

// install_reason is why the executable at exe is not to be replaced, .None
// when it is.
install_reason :: proc(exe: string) -> Reason {
	if selfupdate.is_link(exe) {
		return .Link
	}
	switch install_of(exe, os.get_env("APPIMAGE", context.temp_allocator) != "") {
	case .Loose:
		return .None
	case .Bundle:
		return .Bundle
	case .Package:
		return .Package
	case .App_Image:
		return .App_Image
	case .Installer:
		return .Installer
	}
	return .None
}

// refusal_text words a refusal for the command line.
refusal_text :: proc(why: Reason, version: string) -> string {
	what: string
	#partial switch why {
	case .Link:
		what = "this copy is a link, as a checkout installs it, not a file update may replace"
	case .Bundle:
		what = "this copy is inside Leita.app, whose signature seals it, so it cannot be replaced file by file; the app is replaced whole"
	case .Package:
		what = "this copy belongs to a package manager, which updates it"
	case .App_Image:
		what = "this copy is inside an AppImage, which is not a file to replace"
	case .Installer:
		what = "this copy was put in Program Files by the installer, which updates it"
	}
	return fmt.tprintf("%s is out and %s; download it from %s", version if version != "" else "a newer release", what, RELEASE_PAGE)
}

/*
Release is what a check learned: where the executable is, and the sums it
read, for apply to route by. want is the published hash of the asset.
*/
Release :: struct {
	exe:  string,
	sums: ^selfupdate.Fixed(SUMS_CAP),
	want: string, // into sums
	have: [selfupdate.HEX_DIGEST]byte,
}

// inspect reads the release's sums, checks them, and sets r's outcome to
// Current or Available; ok is false when it set Failed instead.
@(private)
inspect :: proc(cfg: Config, r: ^Result) -> (rel: Release, ok: bool) {
	if cfg.asset == "" {
		finish(r, .Failed, .Unsupported, "no release is built for %s/%s", ODIN_OS_STRING, ODIN_ARCH_STRING)
		return
	}
	rel.exe = cfg.exe
	if rel.exe == "" {
		p, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			finish(r, .Failed, .Cannot_Replace, "cannot find this executable: %v", err)
			return
		}
		rel.exe = p
	}
	if len(rel.exe) + 8 >= selfupdate.PATH_CAP {
		finish(r, .Failed, .Cannot_Replace, "executable path longer than %d bytes", selfupdate.PATH_CAP)
		return
	}
	rel.sums = new(selfupdate.Fixed(SUMS_CAP), context.temp_allocator)
	if got := fetch(cfg, selfupdate.SUMS_FILE, selfupdate.fixed_writer(rel.sums)); got != .Ok {
		fail_fetch(r, got, selfupdate.SUMS_FILE)
		return
	}
	if !signed_ok(cfg, rel.sums, r) {
		return
	}
	ver: selfupdate.Fixed(selfupdate.VERSION_CAP)
	if fetch(cfg, selfupdate.VERSION_FILE, selfupdate.fixed_writer(&ver)) == .Ok {
		r.latest_len = copy(r.latest_buf[:], strings.trim_space(selfupdate.fixed_string(&ver)))
	}
	want, found := selfupdate.published_hash_lookup(selfupdate.fixed_string(rel.sums), cfg.asset)
	if !found {
		finish(r, .Failed, .Not_Published, "%s is not in the release", cfg.asset)
		return
	}
	rel.want = want
	if err := selfupdate.file_hash(rel.exe, rel.have[:]); err != nil {
		finish(r, .Failed, .Cannot_Replace, "cannot read %s: %v", rel.exe, err)
		return
	}
	ok = true
	switch {
	case strings.equal_fold(string(rel.have[:]), want),
	     !is_development(cfg.version) && latest(r) != "" && latest(r) == cfg.version:
		finish(r, .Current, .None, "up to date")
	case latest(r) == "":
		finish(r, .Available, .None, "a newer release is available")
	case:
		finish(r, .Available, .None, "%s is available", latest(r))
	}
	return
}

// signed_ok is whether the sums may be trusted: always when no key is set,
// else when sha256sums.txt.sig verifies under it.
@(private)
signed_ok :: proc(cfg: Config, sums: ^selfupdate.Fixed(SUMS_CAP), r: ^Result) -> bool {
	key := cfg.public_key
	decoded: [32]byte
	if key == nil && SIGNING_KEY != "" {
		selfupdate.key_from_hex(SIGNING_KEY, decoded[:])
		key = decoded[:]
	}
	if key == nil {
		return true
	}
	sig: selfupdate.Fixed(64)
	if got := fetch(cfg, selfupdate.SIG_FILE, selfupdate.fixed_writer(&sig)); got != .Ok {
		fail_fetch(r, got, selfupdate.SIG_FILE)
		return false
	}
	if !selfupdate.verify(key, selfupdate.fixed_bytes(sums), selfupdate.fixed_bytes(&sig)) {
		finish(r, .Failed, .Bad_Signature, "the signature of %s does not verify", selfupdate.SUMS_FILE)
		return false
	}
	return true
}

@(private)
fail_fetch :: proc(r: ^Result, got: Fetch, name: string) {
	switch got {
	case .Ok:
	case .No_Library:
		finish(
			r,
			.Failed,
			.No_Library,
			"libcurl is needed to reach the release and this system has none; install it (libcurl4 on Debian and Ubuntu, libcurl on Fedora), or download from %s",
			RELEASE_PAGE,
		)
	case .Unreachable:
		finish(r, .Failed, .Unreachable, "cannot reach %s", name)
	case .Missing:
		finish(r, .Failed, .Not_Published, "the release has no %s", name)
	}
}

// Fetch is how a request for one of the release's files ended.
Fetch :: enum {
	Ok,
	// The file is not there: an HTTP error status, or no such file on disk.
	Missing,
	Unreachable,
	No_Library,
}

// fetch writes the release's file name into dst.
@(private)
fetch :: proc(cfg: Config, name: string, dst: io.Writer) -> Fetch {
	base := strings.trim_suffix(cfg.base, "/")
	path: [selfupdate.PATH_CAP]byte
	if !strings.contains(base, "://") {
		ok := selfupdate.copy_file_to(fmt.bprintf(path[:], "%s%c%s", base, selfupdate.SEPARATOR, name), dst)
		return .Ok if ok else .Missing
	}
	res, err := http.stream(
		"GET",
		fmt.bprintf(path[:], "%s/%s", base, name),
		dst,
		{timeout = cfg.timeout if cfg.timeout != 0 else DEFAULT_TIMEOUT, user_agent = cfg.user_agent},
	)
	switch {
	case err == .No_Library:
		return .No_Library
	case err != .None:
		return .Unreachable
	case !res.ok:
		return .Missing
	}
	return .Ok
}

@(private)
fetch_to_file :: proc(cfg: Config, name, dest: string) -> Fetch {
	f, err := os.create(dest)
	if err != nil {
		return .Missing
	}
	got := fetch(cfg, name, os.to_writer(f))
	os.close(f)
	if got != .Ok {
		os.remove(dest)
	}
	return got
}

Route :: struct {
	via:    selfupdate.Via,
	ok:     bool,
	reason: Reason,
	note:   string,
}

// obtain writes the release's build to fresh by the cheapest route the signed
// sums list, each verified against its published hash; a route that fails
// falls through to the next.
@(private)
obtain :: proc(cfg: Config, rel: Release, fresh: string) -> (route: Route) {
	rel := rel
	name_buf, dl_buf: [selfupdate.PATH_CAP]byte
	dl := fmt.bprintf(dl_buf[:], "%s.dl", rel.exe)
	defer os.remove(dl)
	sums := selfupdate.fixed_string(rel.sums)

	name := selfupdate.patch_name(name_buf[:], cfg.asset, string(rel.have[:]))
	if step := try_decode(cfg, sums, name, dl, fresh, rel.exe, rel.want); step == .Done {
		return {via = .Patch, ok = true}
	}
	name = fmt.bprintf(name_buf[:], "%s%s", cfg.asset, selfupdate.ZST_EXT)
	if step := try_decode(cfg, sums, name, dl, fresh, "", rel.want); step == .Done {
		return {via = .Compressed, ok = true}
	}
	route.via = .Full
	switch got := fetch_to_file(cfg, cfg.asset, fresh); {
	case got == .No_Library:
		route.reason, route.note = .No_Library, "libcurl is not on this system"
	case got != .Ok:
		route.reason, route.note = .Unreachable, "the download failed"
	case !selfupdate.hash_matches(fresh, rel.want):
		route.reason, route.note = .Bad_Download, "the file does not match its published hash"
	case:
		route.ok = true
		return
	}
	os.remove(fresh)
	return
}

Step :: enum {
	Done,
	Not_Listed,
	Failed,
}

// try_decode fetches name to dl, checks it against its published hash, and
// decodes it into fresh with the file at prefix, if any, as the zstd prefix;
// fresh must then hash to want.
@(private)
try_decode :: proc(cfg: Config, sums, name, dl, fresh, prefix, want: string) -> Step {
	published, listed := selfupdate.published_hash_lookup(sums, name)
	if !listed {
		return .Not_Listed
	}
	if fetch_to_file(cfg, name, dl) != .Ok || !selfupdate.hash_matches(dl, published) {
		return .Failed
	}
	if !selfupdate.decode(dl, fresh, prefix) || !selfupdate.hash_matches(fresh, want) {
		os.remove(fresh)
		return .Failed
	}
	return .Done
}
