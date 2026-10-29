#+build linux
package leita_view

import "core:os"
import "core:strings"
import "core:time"

@(private, thread_local)
linux_dark: bool

@(private, thread_local)
linux_at: i64

@(private, thread_local)
portal_skip_until: i64

// system_dark reports whether the desktop asks apps to draw dark. A session
// bus, when there is one, is asked for color-scheme at most once a second,
// and given up on for half a minute when it does not answer. Otherwise the
// gtk and KDE config files are read. Unknown is light.
system_dark :: proc() -> bool {
	now := time.tick_now()._nsec
	if linux_at != 0 && now - linux_at < i64(time.Second) {
		return linux_dark
	}
	linux_at = now
	if dark, ok := scheme_dark(); ok {
		linux_dark = dark
		return dark
	}
	if dark, ok := config_dark(); ok {
		linux_dark = dark
		return dark
	}
	linux_dark = false
	return false
}

// config_dark reads the gtk and KDE files a desktop writes. The first that
// names a theme decides.
@(private)
config_dark :: proc() -> (dark, ok: bool) {
	dir, derr := os.user_config_dir(context.temp_allocator)
	if derr != nil || dir == "" {
		return
	}
	rels := [3]string{"gtk-4.0/settings.ini", "gtk-3.0/settings.ini", "kdeglobals"}
	for rel in rels {
		path, perr := strings.concatenate({dir, "/", rel}, context.temp_allocator)
		if perr != nil {
			return
		}
		text, read := read_text(path)
		if !read {
			continue
		}
		if dark, ok = text_dark(text); ok {
			return
		}
	}
	return
}

// text_dark reads a gtk settings.ini or kdeglobals. A prefer-dark key decides;
// otherwise a theme name containing "dark" does.
@(private)
text_dark :: proc(text: string) -> (dark, ok: bool) {
	prefer := ""
	name := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == ';' || trimmed[0] == '[' {
			continue
		}
		key, _, val := strings.partition(trimmed, "=")
		key = strings.trim_space(key)
		val = strings.trim_space(val)
		switch key {
		case "gtk-application-prefer-dark-theme":
			prefer = val
		case "gtk-theme-name", "ColorScheme", "LookAndFeelPackage":
			if name == "" {
				name = val
			}
		}
	}
	switch prefer {
	case "1", "true", "True", "yes":
		return true, true
	case "0", "false", "False", "no":
		return false, true
	}
	if name == "" {
		return
	}
	low := strings.to_lower(name, context.temp_allocator)
	return strings.contains(low, "dark"), true
}

// scheme_dark asks gsettings for color-scheme. prefer-dark and prefer-light
// decide; default does not, so the config files can.
@(private)
scheme_dark :: proc() -> (dark, ok: bool) {
	if os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator) == "" {
		return
	}
	now := time.tick_now()._nsec
	if now < portal_skip_until {
		return
	}
	text, ran := ask(
		[]string{"gsettings", "get", "org.gnome.desktop.interface", "color-scheme"},
	)
	if !ran {
		portal_skip_until = now + i64(30 * time.Second)
		return
	}
	if strings.contains(text, "prefer-dark") {
		return true, true
	}
	if strings.contains(text, "prefer-light") {
		return false, true
	}
	return
}

@(private)
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// ask runs args and returns what it wrote, or ran false when it does not
// finish within a fifth of a second or exits badly. The wait is the bound
// on a session bus that never answers.
@(private)
ask :: proc(args: []string) -> (text: string, ran: bool) {
	r, w, perr := os.pipe()
	if perr != nil {
		return
	}
	defer os.close(r)
	p, serr := os.process_start({command = args, stdout = w})
	os.close(w)
	if serr != nil {
		return
	}
	state, werr := os.process_wait(p, 200 * time.Millisecond)
	if werr != nil || !state.exited {
		_ = os.process_kill(p)
		state, _ = os.process_wait(p)
	}
	buf: [128]byte
	n, _ := os.read(r, buf[:])
	if n < 0 {
		n = 0
	}
	return strings.clone(string(buf[:n]), context.temp_allocator), state.exited && state.exit_code == 0
}
