package leita_cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../human"
import "../ntfs"
import "../scan"
import "../term"

/*
How the command line says things. Everything it prints goes through here, so
one decision covers it: style is what the summary on standard output may
carry and estyle what standard error may, plain unless a person is watching
that stream, so a pipe, a script, an agent and every test read the words
alone. run sets both once, from --color, LEITA_COLOR and the streams
themselves; a test never does, and gets the zero value, plain.
*/
style, estyle: term.Style

// LABEL is the column the summary's labels are padded to, so their values
// line up: "tree       106 slots".
LABEL :: 10

// bold and dim are text with that weight, on a terminal; text is made safe to
// print either way (term.paint).
bold :: proc(text: string) -> string {
	return term.painted(style, {.Bold}, text)
}

dim :: proc(text: string) -> string {
	return term.painted(style, {.Dim}, text)
}

// SYNTHETIC_NOTE is what the summary's first line adds when the disk is made up,
// so a demo's figures are not read as someone's files.
SYNTHETIC_NOTE :: "This is a made-up disk: " + scan.SYNTHETIC_ENV + " was set."

// head_line is the summary's first line: what is scanned, where, and how it is
// read; a made-up disk says so at its end.
head_line :: proc(target: scan.Target, engine: scan.Engine, io: ntfs.IO_Mode) -> string {
	line := fmt.tprintf(
		"%s %s on %s %s",
		dim("leita:"),
		bold(scan.location(target, context.temp_allocator)),
		human.shown(target.volume),
		dim(fmt.tprintf("(%v, %v media, %v engine, %v io)", target.fs, target.media, engine, io)),
	)
	if engine == .Synthetic {
		line = strings.concatenate({line, " ", SYNTHETIC_NOTE}, context.temp_allocator)
	}
	return line
}

// label writes one line of the summary: name in bold, padded to LABEL, then
// what it says.
label :: proc(name: string, format: string, args: ..any) {
	label_to(os.to_writer(os.stdout), name, format, ..args)
}

// label_to is label on w, as leita licence and leita update write theirs.
label_to :: proc(w: io.Writer, name: string, format: string, args: ..any) {
	pad := strings.repeat(" ", max(LABEL - len(name), 0) + 1, context.temp_allocator)
	fmt.wprintfln(w, "%s%s%s", bold(name), pad, human.shown(fmt.tprintf(format, ..args)))
}

// say_heading opens a list: its name in bold, the count dim beside it.
say_heading :: proc(name: string, count: int) {
	fmt.println()
	fmt.printfln("%s %s", bold(name), dim(fmt.tprintf("(%d)", count)))
}

// say_line is a line of standard error: prefix in bold, then what format makes of
// args, made safe to print since it may name a file.
say_line :: proc(prefix, format: string, args: ..any) -> string {
	return fmt.tprintf(
		"%s %s",
		term.painted(estyle, {.Bold}, prefix),
		human.shown(fmt.tprintf(format, ..args)),
	)
}

// say_error says what went wrong on standard error, the prefix in bold.
say_error :: proc(format: string, args: ..any) {
	fmt.eprintln(say_line("error:", format, ..args))
}

// say_note says what a person should know, on standard error so a report on
// standard output stays whole.
say_note :: proc(format: string, args: ..any) {
	fmt.eprintln(say_line("note:", format, ..args))
}

/*
say_unread says how many directories the scan could not open, on standard error as
a warning rather than a failure: the tree is short of them, not wrong. On macOS a
refusal for want of permission is commonly a folder the system guards under the home
directory, such as Library/Mail, which Full Disk Access for the terminal lifts.
*/
say_unread :: proc(t: ^scan.Tree) {
	count, denied := scan.unread(t)
	if count == 0 {
		return
	}
	hint := ""
	if ODIN_OS == .Darwin && denied {
		hint = "; grant Full Disk Access to your terminal in System Settings › Privacy & Security › Full Disk Access"
	}
	say_note("%d %s could not be read%s", count, "folder" if count == 1 else "folders", hint)
}
