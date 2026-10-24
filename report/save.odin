package report

import "core:os"
import "core:strings"

import "../faults"

/*
save writes r as format to the file at path, replacing any there. It is written whole
to a sibling, path with ".partial" appended, and renamed over path only once it is,
so a report that cannot be written, or a process stopped part way, leaves the file
path held before as it was. opened is why the sibling could not be made, nil when it
was; the sibling is removed when the rename does not happen. Its name is made in
allocator.
*/
save :: proc(
	path: string,
	r: ^Report,
	format: Format,
	paper := Paper.A4,
	allocator := context.temp_allocator,
) -> (
	err: Error,
	opened: os.Error,
) {
	stage := strings.concatenate({path, ".partial"}, allocator)
	f, open_err := faults.open(stage, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		return .Write_Failed, open_err
	}

	err = export(faults.to_writer(f), r, format, paper)
	if err == .None && faults.sync(f) != nil {
		err = .Write_Failed
	}

	if close_err := os.close(f); close_err != nil && err == .None {
		err = .Write_Failed
	}
	if err == .None && faults.rename(stage, path) != nil {
		err = .Write_Failed
	}
	if err != .None {
		faults.remove(stage)
	}
	return err, nil
}
