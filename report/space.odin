package report

import "../ntfs"
import "../scan"
import "../survey"
import "../synth"

/*
space_of is what the volume a finished scan read holds and has free, when the
engine that read it knows: the MFT reads it from the boot sector and $Bitmap,
synth makes it up for its made-up day, and a walk asks the filesystem it is
mounted on. The command line's scan and the monitor's ask it the same way.
*/
space_of :: proc(f: ^survey.Fill) -> Maybe(Space) {
	#partial switch f.engine {
	case .Synthetic:
		total, free := synth.space(f.target.day)
		return Space{total, free}
	case .Mft:
		if space, ok := mft_space(&f.table).?; ok {
			return space
		}
		// An update from a baseline reads no table, and without this a monitor
		// on an elevated Windows run heard of its disk once, on the whole read.
		// The volume answers as it does for a walk.
		fallthrough
	case .Walk:
		if total, free, ok := scan.space(scan.location(f.target, context.temp_allocator)); ok {
			return Space{total, free}
		}
	}
	return nil
}

// mft_space is what an NTFS volume holds and has free, from its boot sector and
// $Bitmap.
@(private)
mft_space :: proc(m: ^ntfs.Mft) -> Maybe(Space) {
	total := m.boot.total_sectors * u64(m.boot.bytes_per_sector)
	used := m.stats.allocated_clusters * u64(m.boot.bytes_per_cluster)
	if total == 0 || used == 0 || used > total {
		return nil
	}
	return Space{total = total, free = total - used}
}
