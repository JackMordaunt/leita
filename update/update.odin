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
each of the last few releases, sha256sums.txt over all of them, version.txt
and released.txt. sha256sums.txt.sig is the Ed25519 signature of that sums
file. SIGNING_KEY is the public half, compiled in with -define:LEITA_UPDATE_KEY.
Nothing is trusted until that signature verifies. A build with no key, a
missing signature, or a signature that does not verify fails closed: the
hashes alone do not make a release. version.txt is display only, and only
when its own hash is the one the signed sums name; an unsigned version string
does not mark this build current.

released.txt is that release's instant, the canonical UTC form and one line
feed, and it is listed in the sums. It is authenticated only when the
signature verifies and the file's hash is the one the sums name. An update
exists when the published hash of this binary's asset differs from the hash
of the running executable, unless that authenticated version.txt names the
version already running; no version is compared as greater or less. It is
installed by the cheapest route the sums list: the patch from this build,
then the compressed asset, then the asset itself. A download is checked
against its published hash before anything reads it, and what it decodes to
against the asset's; one that fails falls through to the next route.

A copy that is still Pro for this build's compiled release instant is not
replaced unless the candidate's authenticated instant is at or before the
line's paid-through date. No authenticated instant, or a later one, leaves
the Pro copy where it is. A copy that is not Pro may still install a signed
release. The check reports that a release exists either way; only apply
refuses.

The executable is replaced only while this process holds a lock the operating
system drops when the process ends, so a second update does not share the
scratch names and does not wait. The previous bytes are kept as <exe>.old
first. The new file is then renamed over the one that is running: on Unix
that rename replaces it in one step, and on Windows the rename uses POSIX
semantics, so the launch path is never removed first. If the program is
missing and <exe>.old remains, the next apply puts that copy back before it
downloads anything, and it deletes a leftover <exe>.new rather than trusting
it. A directory that will not take a file beside the executable is left
untouched. Only a copy leita can replace is replaced: a development build, a
package's file, Scoop's copy, the Linux recorder's own binary, an AppImage,
an installer's Program Files copy, and anything inside Leita.app are refused,
with the page to download from. A symbolic link is followed to the file it
names, and that file is what is classified and replaced; a loop, or a link
that does not name a file, is refused.
The recorder is not stopped or restarted from here: its process keeps the
inode it opened, and `leita journal on` is what copies a new binary into
place. A signed bundle's signature covers every file in its Contents
(Apple's Code Signing Guide), so a file replaced inside it fails
codesign --verify. The window and the command line inside the bundle are
replaced together, by the dmg.

Why not selfupdate.run: run fetches with jm:http's own User-Agent and
re-executes the new binary. This package uses selfupdate's pieces, the
hashes and the decoder, and fetches itself. It does not relaunch, and it
does not call selfupdate.swap: that removes the launch path before the new
file takes its place.
*/
package update

import "core:bytes"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "../history/place"
import "../licence"
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
SIGNING_KEY is the Ed25519 public key, 64 hex characters, that verifies
sha256sums.txt.sig. The release build sets it with -define:LEITA_UPDATE_KEY.
Empty in a development build. No environment variable replaces it: an empty
or malformed key fails closed, and a signature that does not verify under
this key is not a release.
*/
SIGNING_KEY :: #config(LEITA_UPDATE_KEY, "")

// RELEASED_FILE is the release's instant: 20 bytes, YYYY-MM-DDTHH:MM:SSZ, and
// one LF. The release workflow writes it and lists it in sha256sums.txt.
RELEASED_FILE :: "released.txt"

// JOURNAL_COPY is the recorder binary `leita journal on` installs from an
// archive. It matches journal.BINARY_PATH. The package install is
// /usr/libexec/leita/leita, which the /usr prefix already refuses.
JOURNAL_COPY :: "/usr/local/libexec/leita/leita"

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
//review:ignore verb-for-func it only returns that file name; a producer is named for the value, as message and latest are
asset :: proc(b: Binary) -> string {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		return "leita-linux-amd64" if b == .Command_Line else "leita-window-linux-amd64"
	} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
		return "leita-linux-arm64" if b == .Command_Line else "leita-window-linux-arm64"
	} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
		return(
			"leita-windows-amd64.exe" if b == .Command_Line else "leita-window-windows-amd64.exe" \
		)
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
	// The archive install of the Linux recorder. A running service keeps this inode.
	Journal,
	// Scoop's own app directory. Scoop updates it.
	Scoop,
}

/*
install_of says how the executable at exe was installed. app_image is whether
the AppImage runtime's APPIMAGE variable is set; the path alone gives away
the rest.
*/
install_of :: proc(
	exe: string,
	app_image := false,
	allocator := context.temp_allocator,
) -> Install {
	p, _ := strings.replace_all(exe, "\\", "/", allocator)
	lower := strings.to_lower(p, allocator)
	switch {
	case strings.contains(p, ".app/Contents/"):
		return .Bundle
	case app_image || strings.contains(p, "/.mount_"):
		return .App_Image
	case strings.contains(lower, "/program files"):
		return .Installer
	case p == JOURNAL_COPY:
		return .Journal
	case strings.contains(lower, "/scoop/apps/"):
		return .Scoop
	case strings.has_prefix(p, "/usr/") &&
	     !strings.has_prefix(p, "/usr/local/"),
	     strings.has_prefix(p, "/opt/homebrew/"),
	     strings.contains(p, "/Cellar/"),
	     strings.has_prefix(p, "/nix/store/"),
	     strings.has_prefix(p, "/snap/"):
		return .Package
	}
	return .Loose
}

// Hold is whether this installation is still Pro, and until which instant.
// retained is true only for an annual line that entitles this build's
// compiled release instant. A trial is not retained Pro.
Hold :: struct {
	retained:     bool,
	paid_through: string,
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
	// 32 raw bytes of the key sha256sums.txt.sig must verify under. Nil uses
	// SIGNING_KEY. A missing or wrong-sized key fails closed.
	public_key: []byte,
	// Whole-request timeout for each download. 0 means DEFAULT_TIMEOUT.
	timeout:    time.Duration,
	// hold_known means hold is already decided and the licence file is not read.
	// The command line and the window leave it false.
	hold_known: bool,
	// hold is used when hold_known is set. Tests pass a retained Pro line here.
	hold:       Hold,
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
	// This copy is still Pro, and the candidate is not eligible for that line.
	Ineligible,
	// The Linux recorder's binary. Left running; journal on copies a new one.
	Journal,
	// Scoop owns this directory.
	Scoop,
}

// Result is returned by value; message, latest and released read its buffers.
Result :: struct {
	outcome:      Outcome,
	reason:       Reason,
	// The route an Applied update took.
	via:          selfupdate.Via,
	message_buf:  [384]byte,
	message_len:  int,
	latest_buf:   [selfupdate.VERSION_CAP]byte,
	latest_len:   int,
	released_buf: [20]byte, // canonical instant, when released_ok
	released_ok:  bool,
}

// message says what happened, in English, for the command line.
message :: proc(r: ^Result) -> string {
	return string(r.message_buf[:r.message_len])
}

// latest is the release's version from version.txt, "" when it was not read
// or its hash was not the one the signed sums name.
latest :: proc(r: ^Result) -> string {
	return string(r.latest_buf[:r.latest_len])
}

// released is the candidate release's authenticated instant. ok is false when
// the manifest was unsigned, or the stamp was missing, tampered or not the
// canonical form: nothing there is a paid-through cutoff.
released :: proc(r: ^Result) -> (at: string, ok: bool) {
	if !r.released_ok {
		return
	}
	return string(r.released_buf[:]), true
}

// not_replaceable says whether reason is that this copy is not one to replace,
// as opposed to a failure: the caller points to RELEASE_PAGE.
not_replaceable :: proc(reason: Reason) -> bool {
	#partial switch reason {
	case .Link, .Bundle, .Package, .App_Image, .Installer, .Journal, .Scoop:
		return true
	}
	return false
}

@(private)
finish :: proc(
	r: ^Result,
	outcome: Outcome,
	reason: Reason,
	format: string,
	args: ..any,
) -> Result {
	r.outcome, r.reason = outcome, reason
	r.message_len = len(fmt.bprintf(r.message_buf[:], format, ..args))
	return r^
}

// default_config is the configuration of this process: b's asset, this build's
// version, the release's base unless BASE_ENV names another. The licence in
// use is read at apply, so a retained Pro copy is not replaced by an
// ineligible release.
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
which version), or Failed. An unauthenticated manifest is Failed.
*/
check :: proc(cfg: Config) -> (r: Result) {
	inspect(cfg, &r)
	return r
}

/*
apply installs the release's build over the running executable when it
differs: Applied, Current when there is nothing to do, Refused for a copy that
is not to be replaced (the message says where to download) or for a release
this Pro installation may not take, or Failed. It is the caller's to restart
into the new build.
*/
apply :: proc(cfg: Config, allocator := context.temp_allocator) -> (r: Result) {
	if is_development(cfg.version) {
		return finish(
			&r,
			.Refused,
			.Dev_Build,
			"this is a development build, not a release; update replaces releases only",
		)
	}
	exe := cfg.exe
	if exe == "" {
		p, err := os.get_executable_path(allocator)
		if err != nil {
			return finish(&r, .Failed, .Cannot_Replace, "cannot find this executable: %v", err)
		}
		exe = p
	}
	if len(exe) + len(LOCK_SUFFIX) >= selfupdate.PATH_CAP {
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"executable path longer than %d bytes",
			selfupdate.PATH_CAP,
		)
	}
	// The real file is named before any lock or scratch write, so a package
	// path, including one reached by a link, is refused with nothing created.
	real, why, located := resolve_exe(exe)
	if !located {
		if why == .Link {
			return finish(&r, .Refused, why, "%s", refusal_text(why, ""))
		}
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not resolve %s, so it was not replaced",
			exe,
		)
	}
	if len(real) + len(LOCK_SUFFIX) >= selfupdate.PATH_CAP {
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"executable path longer than %d bytes",
			selfupdate.PATH_CAP,
		)
	}
	if selfupdate.is_link(real) {
		return finish(&r, .Refused, .Link, "%s", refusal_text(.Link, ""))
	}
	if why = install_reason(real); why != .None {
		return finish(&r, .Refused, why, "%s", refusal_text(why, ""))
	}
	// Held before scratch is removed, and until this procedure returns. The
	// system drops it if the process is killed.
	held, how := lock_install(real)
	defer unlock_install(&held)
	switch how {
	case .Held:
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"another update is already replacing %s",
			real,
		)
	case .Failed:
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not lock %s, so it was not replaced",
			real,
		)
	case .Taken:
	}
	if !restore_target(real, &r) {
		return r
	}
	if !can_write_beside(real) {
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"cannot write beside %s, so it was not replaced",
			real,
		)
	}

	cfg := cfg
	cfg.exe = real
	rel, ok := inspect(cfg, &r)
	if !ok || r.outcome != .Available {
		return r
	}
	hold := cfg.hold if cfg.hold_known else hold_in_use(allocator)
	if !hold_allows(hold, &r) {
		return refuse_ineligible(&r, hold)
	}

	fresh_buf: [selfupdate.PATH_CAP]byte
	fresh := fmt.bprintf(fresh_buf[:], "%s.new", rel.exe)
	route := obtain(cfg, rel, fresh)
	if !route.ok {
		return finish(&r, .Failed, route.reason, "cannot download %s: %s", cfg.asset, route.note)
	}
	status, note := commit_verified(rel.exe, fresh)
	switch status {
	case .Ok:
	case .Backup:
		os.remove(fresh)
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not keep a copy of %s, so it was not replaced",
			rel.exe,
		)
	case .Permission:
		os.remove(fresh)
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not keep the permissions of %s, so it was not replaced",
			rel.exe,
		)
	case .Hold:
		os.remove(fresh)
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not hold the update before installing %s, so it was not replaced",
			rel.exe,
		)
	case .Unsupported:
		os.remove(fresh)
		return finish(&r, .Failed, .Cannot_Replace, "%s", note)
	case .Replace:
		os.remove(fresh)
		return finish(
			&r,
			.Failed,
			.Cannot_Replace,
			"could not install %s: %s. It was not replaced",
			rel.exe,
			note,
		)
	}
	r.via = route.via
	return finish(&r, .Applied, .None, "updated via %s", selfupdate.VIA_NAMES[route.via])
}

// why_not is why cfg's executable is not to be replaced in place, Dev_Build or
// an install_reason, .None when it is: what a window asks to choose between
// installing the update and sending a person to RELEASE_PAGE. Eligibility is
// decided in apply, once the candidate's instant is known.
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
	real, why, located := resolve_exe(exe)
	if !located {
		return why
	}
	if selfupdate.is_link(real) {
		return .Link
	}
	return install_reason(real)
}

// install_reason is why the resolved file at exe is not to be replaced, .None
// when it is. Callers resolve links first; a path that is still a link is
// their concern.
install_reason :: proc(exe: string, allocator := context.temp_allocator) -> Reason {
	switch install_of(exe, os.get_env("APPIMAGE", allocator) != "", allocator) {
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
	case .Journal:
		return .Journal
	case .Scoop:
		return .Scoop
	}
	return .None
}

// refusal_text words a refusal for the command line. version may be "" when
// the release was not asked, which is how apply refuses before it downloads.
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
	case .Journal:
		what = "this copy is the recorder's binary, and leita update does not replace it or restart the service; update the copy you run, then sudo leita journal on installs that copy and restarts the recorder"
	case .Scoop:
		what = "this copy belongs to Scoop, which updates it"
	}
	return fmt.tprintf(
		"%s is out and %s; download it from %s",
		version if version != "" else "a newer release",
		what,
		RELEASE_PAGE,
	)
}

// restore_target puts an interrupted update back, before anything is
// downloaded. A target that is missing is renamed back from <exe>.old when
// that file exists. A leftover <exe>.new is deleted: it was not checked
// against the release this run authenticated.
@(private)
restore_target :: proc(exe: string, r: ^Result) -> bool {
	old_buf, fresh_buf, dl_buf, try_buf, part_buf: [selfupdate.PATH_CAP]byte
	old := fmt.bprintf(old_buf[:], "%s.old", exe)
	fresh := fmt.bprintf(fresh_buf[:], "%s.new", exe)
	dl := fmt.bprintf(dl_buf[:], "%s.dl", exe)
	probe := fmt.bprintf(try_buf[:], "%s.try", exe)
	part := fmt.bprintf(part_buf[:], "%s%s", exe, PART_SUFFIX)
	if !os.exists(exe) && os.exists(old) {
		if err := os.rename(old, exe); err != nil {
			finish(
				r,
				.Failed,
				.Cannot_Replace,
				"an interrupted update left %s missing and %s could not be restored: %v",
				exe,
				old,
				err,
			)
			return false
		}
	}
	os.remove(fresh)
	os.remove(dl)
	os.remove(probe)
	os.remove(part)
	// The lock file is not removed. The operating system holds it.
	if !os.exists(exe) {
		finish(r, .Failed, .Cannot_Replace, "cannot find %s to replace", exe)
		return false
	}
	return true
}

// can_write_beside says whether a file can be created next to exe. The probe
// is removed. A failure here means apply has not renamed the executable.
@(private)
can_write_beside :: proc(exe: string) -> bool {
	probe_buf: [selfupdate.PATH_CAP]byte
	probe := fmt.bprintf(probe_buf[:], "%s.try", exe)
	if os.write_entire_file(probe, "x") != nil {
		return false
	}
	os.remove(probe)
	return true
}

// hold_of is the retained-Pro fact of l at release_at. pro_entitled is the
// same comparison the running build uses, so a release instant that does not
// entitle this build is not a reason to block a later one.
@(private)
hold_of :: proc(l: licence.Licence, release_at: string) -> Hold {
	if !licence.pro_entitled(l, release_at) {
		return {}
	}
	return {retained = true, paid_through = l.paid_through}
}

// hold_in_use reads the licence this process runs under: LEITA_LICENCE, else
// the file beside the history store. A line that does not verify, a build
// with no compiled release instant, and a trial are not retained Pro.
@(private)
hold_in_use :: proc(allocator := context.temp_allocator) -> Hold {
	kept := place.default_path(allocator)
	given := os.get_env(licence.ENV, allocator)
	l, from, err := licence.in_use(licence.path_beside(kept, allocator), given)
	if err != .None || from == .None {
		return {}
	}
	at, ok := licence.this_release()
	if !ok {
		return {}
	}
	return hold_of(l, at)
}

// hold_allows says whether hold permits installing the candidate r describes.
// A copy that is not retained Pro is allowed. A retained one needs an
// authenticated instant at or before paid_through.
@(private)
hold_allows :: proc(hold: Hold, r: ^Result) -> bool {
	if !hold.retained {
		return true
	}
	at, stamped := released(r)
	return stamped && licence.instant_ok(hold.paid_through) && at <= hold.paid_through
}

@(private)
refuse_ineligible :: proc(r: ^Result, hold: Hold) -> Result {
	at, stamped := released(r)
	if !stamped || !licence.instant_ok(hold.paid_through) {
		return finish(
			r,
			.Refused,
			.Ineligible,
			"this copy is still Pro through %s; the release has no authenticated release instant, so it was not installed",
			hold.paid_through,
		)
	}
	name := latest(r)
	if name == "" {
		name = "the release"
	}
	return finish(
		r,
		.Refused,
		.Ineligible,
		"this copy is still Pro through %s; %s was released %s, which is after that, so it was not installed",
		hold.paid_through,
		name,
		at,
	)
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
		finish(
			r,
			.Failed,
			.Unsupported,
			"no release is built for %s/%s",
			ODIN_OS_STRING,
			ODIN_ARCH_STRING,
		)
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
		finish(
			r,
			.Failed,
			.Cannot_Replace,
			"executable path longer than %d bytes",
			selfupdate.PATH_CAP,
		)
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
	sums := selfupdate.fixed_string(rel.sums)
	read_released(cfg, sums, r)
	read_version(cfg, sums, r)
	want, found := selfupdate.published_hash_lookup(sums, cfg.asset)
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
	     !is_development(cfg.version) &&
	     latest(r) != "" &&
	     latest(r) == cfg.version:
		finish(r, .Current, .None, "up to date")
	case latest(r) == "":
		finish(r, .Available, .None, "a newer release is available")
	case:
		finish(r, .Available, .None, "%s is available", latest(r))
	}
	return
}

// signed_ok is whether the sums verified under the release key. No key, a
// missing signature and a bad signature are all failures.
@(private)
signed_ok :: proc(cfg: Config, sums: ^selfupdate.Fixed(SUMS_CAP), r: ^Result) -> bool {
	decoded: [32]byte
	key, ok := resolve_key(cfg, decoded[:])
	if !ok {
		why := "this build has no release signing key, so the manifest cannot be authenticated"
		if len(cfg.public_key) > 0 || SIGNING_KEY != "" {
			why = "the release signing key is not an Ed25519 public key, so the manifest cannot be authenticated"
		}
		finish(r, .Failed, .Bad_Signature, "%s", why)
		return false
	}
	sig: selfupdate.Fixed(64)
	if got := fetch(cfg, selfupdate.SIG_FILE, selfupdate.fixed_writer(&sig)); got != .Ok {
		if got == .Missing {
			finish(
				r,
				.Failed,
				.Bad_Signature,
				"the release has no signature of %s",
				selfupdate.SUMS_FILE,
			)
			return false
		}
		fail_fetch(r, got, selfupdate.SIG_FILE)
		return false
	}
	if !selfupdate.verify(key, selfupdate.fixed_bytes(sums), selfupdate.fixed_bytes(&sig)) {
		finish(
			r,
			.Failed,
			.Bad_Signature,
			"the signature of %s does not verify",
			selfupdate.SUMS_FILE,
		)
		return false
	}
	return true
}

// resolve_key is the 32-byte public key for this check. cfg.public_key, when
// its length is 32, wins over SIGNING_KEY so a test can use a throwaway key.
// ok is false when neither is a key, which the caller treats as a failure.
@(private)
resolve_key :: proc(cfg: Config, decoded: []byte) -> (key: []byte, ok: bool) {
	if len(cfg.public_key) > 0 {
		return cfg.public_key, len(cfg.public_key) == 32
	}
	if SIGNING_KEY == "" || !selfupdate.key_from_hex(SIGNING_KEY, decoded) {
		return nil, false
	}
	return decoded, true
}

// read_version sets r's latest when version.txt is listed in the signed sums
// and the bytes hash to that line. Anything else leaves latest empty, so a
// substituted version string cannot mark this build current.
@(private)
read_version :: proc(cfg: Config, sums: string, r: ^Result) {
	ver: selfupdate.Fixed(selfupdate.VERSION_CAP)
	if fetch(cfg, selfupdate.VERSION_FILE, selfupdate.fixed_writer(&ver)) != .Ok {
		return
	}
	body := selfupdate.fixed_bytes(&ver)
	if !listed_hash_matches(sums, selfupdate.VERSION_FILE, body) {
		return
	}
	r.latest_len = copy(r.latest_buf[:], strings.trim_space(string(body)))
}

// read_released sets r's stamp when released.txt is the canonical instant, its
// hash is the one the signed sums name, and nothing else. A missing or wrong
// file leaves the outcome alone.
@(private)
read_released :: proc(cfg: Config, sums: string, r: ^Result) {
	stamp: selfupdate.Fixed(32)
	if fetch(cfg, RELEASED_FILE, selfupdate.fixed_writer(&stamp)) != .Ok {
		return
	}
	body := selfupdate.fixed_bytes(&stamp)
	if len(body) != 21 || body[20] != '\n' {
		return
	}
	if !listed_hash_matches(sums, RELEASED_FILE, body) {
		return
	}
	at := string(body[:20])
	if !licence.instant_ok(at) {
		return
	}
	copy(r.released_buf[:], at)
	r.released_ok = true
}

// listed_hash_matches says whether the signed sums name name as the sha256 of body.
@(private)
listed_hash_matches :: proc(sums, name: string, body: []byte) -> bool {
	published, found := selfupdate.published_hash_lookup(sums, name)
	if !found {
		return false
	}
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, string(body), digest[:])
	want: [32]byte
	decoded, ok := hex.decode_into_buffer(transmute([]byte)published, want[:])
	return ok && len(decoded) == 32 && bytes.equal(digest[:], decoded)
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
		ok := selfupdate.copy_file_to(
			fmt.bprintf(path[:], "%s%c%s", base, selfupdate.SEPARATOR, name),
			dst,
		)
		return .Ok if ok else .Missing
	}
	res, err := http.stream(
		"GET",
		fmt.bprintf(path[:], "%s/%s", base, name),
		dst,
		{
			timeout = cfg.timeout if cfg.timeout != 0 else DEFAULT_TIMEOUT,
			user_agent = cfg.user_agent,
		},
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
//review:ignore says-what-not-how this is selfupdate.try_decode's step under leita's own fetch: one listed file, its hash, then the decode. obtain picks the route, so try_obtain would name that parent
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
