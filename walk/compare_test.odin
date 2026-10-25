package walk

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../scan"

// What leita charged a tree, by the figures a tool reports.
Totals :: struct {
	apparent:  u64, // file lengths
	allocated: u64, // Node.disk summed
	files:     int,
	dirs:      int,
}

// totals_of sums the tree as a rollup would: a further name of a file already
// charged adds nothing.
totals_of :: proc(tree: ^scan.Tree, dump := false) -> (sum: Totals) {
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags {continue}
		a, has := scan.account_of(tree, i)
		length := n.disk
		if has && .Logical in a.known {
			length = a.logical
		}
		if dump {
			fmt.eprintfln("  node %-24s flags=%v disk=%d logical=%d", scan.name_of(tree, i), flags, n.disk, length)
		}
		if .Extra_Name in flags {continue}
		if .Directory in flags {
			sum.dirs += 1
		} else {
			sum.files += 1
		}
		sum.apparent += length
		sum.allocated += n.disk
	}
	return
}

// run_tool returns the first word of a command's output, a number.
run_tool :: proc(command: []string) -> (value: u64, text: string, ok: bool) {
	state, out, errout, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return 0, fmt.tprintf("%v %v %s", err, state, errout), false
	}
	text = strings.trim_space(string(out))
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) == 0 {
		return 0, text, false
	}
	v, parsed := strconv.parse_u64(fields[0])
	return v, text, parsed
}

// has_tool says whether the command runs and exits 0.
has_tool :: proc(command: []string) -> bool {
	state, _, _, err := os.process_exec({command = command}, context.temp_allocator)
	return err == nil && state.exited && state.exit_code == 0
}
