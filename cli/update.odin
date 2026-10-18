package leita_cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../term"
import "../update"
import "../version"

/*
leita update: look for a newer leita on the release page, and install it when
asked. Neither happens unless a person runs it: leita never checks at start-up,
on a timer or in the background, and has no setting that does.

Its one request is the download: GET for a file under update.RELEASE_BASE (the
latest GitHub release), with the User-Agent leita/<version>. It sends no key,
path, name or count. LEITA_RELEASE_BASE names another base, or a directory.
A release is trusted by the sha256 it publishes (update.SIGNING_KEY is the
hook for its signature, once the release is signed).

The window and the command line share the package update; which release file
is fetched follows the program running: Leita, the window, takes `Leita update`
as leita does and updates itself.
*/

UPDATE_USAGE :: `leita update — look for a newer leita, and install it when asked.

  leita update --check      say which version this is and which is the latest
                            release; exit 0 when this is the latest, 2 when a
                            newer one is out, 1 when the release could not be asked
  leita update              download the latest release's build of this program,
                            check its sha256 against the release's sha256sums.txt,
                            and replace this program with it; run leita again to
                            use it

Nothing checks on its own: leita asks the release page only when you run this. The
only request is the download, a GET for a file of the latest GitHub release, with the
User-Agent leita/<version>. LEITA_RELEASE_BASE=URL-OR-DIRECTORY asks elsewhere.

A copy installed by a package manager, an AppImage, the Windows installer or inside
Leita.app is not replaced: it says where to download the new one. On Linux the check
needs libcurl, which a stock desktop may lack. On Windows the old program stays beside
the new one, as leita.exe.old, until the next update removes it.

Exit codes: 0 up to date, or updated; 1 an error, or a copy that is not replaced;
2 with --check, a newer release exists.
`

// EXIT_NEWER is --check finding a newer release, which a script reads.
EXIT_NEWER :: 2

// running_as is which of the release's binaries this process is: Leita, the
// window, sets it to .Window before it runs the command line.
running_as := update.Binary.Command_Line

// update_command_line runs leita update on this machine, saying how it went on
// standard output, and returns the exit code.
update_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	set_style(mode)
	return update_dispatch(update.default_config(running_as, version.VERSION), args, os.to_writer(os.stdout))
}

// update_dispatch carries out the leita update command args names against cfg's
// release, saying how it went on w and what went wrong on standard error.
update_dispatch :: proc(cfg: update.Config, args: []string, w: io.Writer) -> int {
	switch {
	case len(args) == 1 && (args[0] == "-h" || args[0] == "--help"):
		b := strings.builder_make(context.temp_allocator)
		term.write_usage(&b, style, "leita update", UPDATE_USAGE)
		fmt.wprint(w, strings.to_string(b))
		return EXIT_OK
	case len(args) == 0:
		return apply_update(cfg, w)
	case len(args) == 1 && args[0] == "--check":
		return check_update(cfg, w)
	}
	say_error("leita update takes --check or nothing, not %q", strings.join(args, " ", context.temp_allocator))
	fmt.eprintln("leita update -h says what it does")
	return EXIT_ERROR
}

// check_update says this version and the release's, and exits by which is newer.
@(private = "file")
check_update :: proc(cfg: update.Config, w: io.Writer) -> int {
	r := update.check(cfg)
	if r.outcome == .Failed {
		say_error("%s", update.message(&r))
		return EXIT_ERROR
	}
	label_to(w, "current", "%s", cfg.version)
	label_to(w, "latest", "%s", latest_of(&r))
	if r.outcome == .Available {
		fmt.wprintfln(w, "a newer leita is out; leita update installs it")
		return EXIT_NEWER
	}
	fmt.wprintln(w, "this is the latest leita")
	return EXIT_OK
}

// apply_update installs the release's build over the running program.
@(private = "file")
apply_update :: proc(cfg: update.Config, w: io.Writer) -> int {
	// Found before the swap, after which this process's own path names the old file.
	cfg := cfg
	if cfg.exe == "" {
		cfg.exe, _ = os.get_executable_path(context.temp_allocator)
	}
	r := update.apply(cfg)
	switch r.outcome {
	case .Current:
		fmt.wprintfln(w, "leita %s is the latest release; nothing to do", cfg.version)
		return EXIT_OK
	case .Applied:
		label_to(w, "updated", "from %s to %s, by %s", cfg.version, latest_of(&r), via_words(&r))
		label_to(w, "replaced", "%s", cfg.exe)
		when ODIN_OS == .Windows {
			label_to(w, "kept", "%s.old, until the next update removes it", cfg.exe)
		} else {
			label_to(w, "kept", "%s.old, the program it replaced", cfg.exe)
		}
		fmt.wprintln(w, "run leita again to use the new one")
		return EXIT_OK
	case .Available, .Refused, .Failed:
		// apply never stops at Available: it installs or says why not.
		say_error("%s", update.message(&r))
	}
	return EXIT_ERROR
}

// latest_of is the release's version, or "unknown" when it did not say.
@(private = "file")
latest_of :: proc(r: ^update.Result) -> string {
	if v := update.latest(r); v != "" {
		return v
	}
	return "unknown"
}

@(private = "file")
via_words :: proc(r: ^update.Result) -> string {
	switch r.via {
	case .Patch:
		return "a patch from this build"
	case .Compressed:
		return "the compressed build"
	case .Full:
		return "the full build"
	}
	return ""
}
