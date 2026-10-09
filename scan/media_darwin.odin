#+build darwin
package scan

import "core:c"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"

foreign import iokit "system:IOKit.framework"
foreign import core_foundation "system:CoreFoundation.framework"

/*
What stores `device`, as the I/O Registry describes the hardware behind it.

A volume is rarely the device that reports its medium: an APFS volume sits in a
container, the container on a partition, the partition on the drive. The search climbs
from the volume through its parents to the first entry carrying the drive's
characteristics, so every volume on one drive gets the drive's answer. A device the
registry does not know, such as a network share's, and a drive that does not say,
such as a card reader, are Unknown.
*/
@(private)
media_of :: proc(device: string) -> Media {
	name := strings.trim_prefix(device, "/dev/")
	if name == "" {
		return .Unknown
	}
	matching := IOBSDNameMatching(
		MAIN_PORT_DEFAULT,
		0,
		strings.clone_to_cstring(name, context.temp_allocator),
	)
	if matching == nil {
		return .Unknown
	}
	// Releases the matching dictionary, found or not: CF_RELEASES_ARGUMENT in IOKitLib.h.
	service := IOServiceGetMatchingService(MAIN_PORT_DEFAULT, matching)
	if service == 0 {
		return .Unknown
	}
	defer IOObjectRelease(service)

	characteristics := IORegistryEntrySearchCFProperty(
		service,
		"IOService",
		CF.TypeRef(CF.STR("Device Characteristics")),
		nil,
		REGISTRY_ITERATE_RECURSIVELY | REGISTRY_ITERATE_PARENTS,
	)
	if characteristics == nil {
		return .Unknown
	}
	defer CF.ReleaseObject(characteristics)
	if CFGetTypeID(characteristics) != CFDictionaryGetTypeID() {
		return .Unknown
	}
	medium := CFDictionaryGetValue(characteristics, CF.TypeRef(CF.STR("Medium Type")))
	if medium == nil || CFGetTypeID(medium) != CFStringGetTypeID() {
		return .Unknown
	}
	buf: [32]u8
	utf8 := CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)
	if !CF.StringGetCString(CF.String(medium), raw_data(buf[:]), len(buf), utf8) {
		return .Unknown
	}
	switch string(cstring(raw_data(buf[:]))) {
	case "Solid State":
		return .Solid
	case "Rotational":
		return .Rotational
	}
	return .Unknown
}

@(private = "file")
MAIN_PORT_DEFAULT :: 0
@(private = "file")
REGISTRY_ITERATE_RECURSIVELY :: 0x1
@(private = "file")
REGISTRY_ITERATE_PARENTS :: 0x2

@(private = "file", default_calling_convention = "c")
foreign iokit {
	IOBSDNameMatching               :: proc(port: u32, options: u32, name: cstring) -> rawptr ---
	IOServiceGetMatchingService     :: proc(port: u32, matching: rawptr) -> u32 ---
	IORegistryEntrySearchCFProperty :: proc(entry: u32, plane: cstring, key: CF.TypeRef, allocator: rawptr, options: u32) -> CF.TypeRef ---
	IOObjectRelease                 :: proc(object: u32) -> c.int ---
}

// What CoreFoundation's own binding leaves out.
@(private = "file", default_calling_convention = "c")
foreign core_foundation {
	CFGetTypeID           :: proc(cf: CF.TypeRef) -> CF.TypeID ---
	CFDictionaryGetTypeID :: proc() -> CF.TypeID ---
	CFStringGetTypeID     :: proc() -> CF.TypeID ---
	CFDictionaryGetValue  :: proc(dict: CF.TypeRef, key: CF.TypeRef) -> CF.TypeRef ---
}
