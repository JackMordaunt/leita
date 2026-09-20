/*
Package ntfs reads the NTFS Master File Table ($MFT) and turns it into a flat table
of entries: one per file record, carrying parent, name, sizes, and flags.

Why read the MFT instead of walking directories: every file on an NTFS volume has a
1 KiB (sometimes 4 KiB) record in one contiguous-ish file, so the whole volume's
metadata is a few sequential reads. Directory enumeration is millions of small random
reads. For a "what is using my disk" tool the MFT route is one to two orders of
magnitude faster.

The parsing code is pure and operates on byte slices, so it is testable without a
volume and portable to other operating systems. Only `volume_windows.odin` touches
the OS. Reading a live volume requires administrator rights.

Layout on disk, in the order this package consumes it:

  boot.odin     boot sector: cluster size, record size, where the MFT starts
  runlist.odin  mapping pairs: which clusters a non-resident attribute occupies
  record.odin   FILE records: fixups, attribute headers, typed attribute views
  mft.odin      the entry table built from records, plus path reconstruction
  reader.odin   orchestration: boot -> record 0 -> $MFT runs -> stream records
*/
package ntfs

#assert(
	ODIN_ENDIAN == .Little,
	"NTFS structures are little-endian; this package reads them in place",
)

Error :: enum {
	None,
	Not_Ntfs, // boot sector OEM id is not "NTFS    "
	Bad_Boot_Sector, // sizes in the boot sector are inconsistent
	Bad_Record, // FILE record magic or fixups do not match
	Bad_Runlist, // mapping pairs are malformed or a read fell outside them
	Mft_Data_Missing, // record 0 has no unnamed non-resident $DATA
	Mft_Spans_Extension_Records, // $MFT's $DATA continues in extension records (attribute list); unsupported
	Open_Failed,
	Access_Denied, // volume handles need administrator rights
	Read_Failed,
	Short_Read,
	Unsupported_Platform,
	Out_Of_Memory,
}

// A file reference packs a 48-bit record number with a 16-bit sequence number.
// The sequence number lets a reference detect that a record was deleted and reused.
File_Ref :: distinct u64

ref_record :: proc "contextless" (r: File_Ref) -> u64 {
	return u64(r) & 0x0000_FFFF_FFFF_FFFF
}

ref_sequence :: proc "contextless" (r: File_Ref) -> u16 {
	return u16(u64(r) >> 48)
}

make_ref :: proc "contextless" (record: u64, sequence: u16) -> File_Ref {
	return File_Ref(record & 0x0000_FFFF_FFFF_FFFF | u64(sequence) << 48)
}

// Well-known record numbers. Records below FIRST_USER_RECORD belong to the file system.
RECORD_MFT        :: 0
RECORD_MFT_MIRROR :: 1
RECORD_LOG_FILE   :: 2
RECORD_VOLUME     :: 3
RECORD_ATTR_DEF   :: 4
RECORD_ROOT       :: 5
RECORD_BITMAP     :: 6
RECORD_BOOT       :: 7
RECORD_BAD_CLUS   :: 8
RECORD_SECURE     :: 9
RECORD_UPCASE     :: 10
RECORD_EXTEND     :: 11
FIRST_USER_RECORD :: 16

// Little-endian readers over byte slices. Slicing panics on out-of-range offsets, so
// callers check lengths first; these only guard the final two-to-eight bytes.
@(private)
rd16 :: proc "contextless" (b: []byte, off: int) -> u16 {
	if off + 2 > len(b) {
		return 0
	}
	return u16(b[off]) | u16(b[off + 1]) << 8
}

@(private)
rd32 :: proc "contextless" (b: []byte, off: int) -> u32 {
	if off + 4 > len(b) {
		return 0
	}
	return u32(rd16(b, off)) | u32(rd16(b, off + 2)) << 16
}

@(private)
rd64 :: proc "contextless" (b: []byte, off: int) -> u64 {
	if off + 8 > len(b) {
		return 0
	}
	return u64(rd32(b, off)) | u64(rd32(b, off + 4)) << 32
}

@(private)
wr16 :: proc "contextless" (b: []byte, off: int, v: u16) {
	if off + 2 > len(b) {
		return
	}
	b[off] = byte(v)
	b[off + 1] = byte(v >> 8)
}
