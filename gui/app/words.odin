package leita_app

import "core:strings"

import "jm:i18n"

import "../../licence"
import "../../reclaim"
import "../../report"
import "../command"
import "../files"
import "../msg"

/*
The host's words: the notices, problems and answers it shows in the window, in
the language the window is in. The view says which with command.Language on its
first frame and on every change, and the host answers every live need again in
it. A notice or problem already given stays in the language it was given in.
*/

// say is key in the window's language with args filled in, in the temp
// allocator.
say :: proc(d: ^Desk, key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.trf(d.words, key, ..args, allocator = context.temp_allocator)
}

// tell replaces the notice the window is shown with key and args, in the
// window's language. The notice owns its text, a clone of what say made.
tell :: proc(d: ^Desk, failed: bool, key: msg.Msg, args: ..i18n.Arg) {
	delete(d.notice.text)
	d.notice = {
		id     = d.notice.id + 1,
		failed = failed,
		text   = strings.clone(say(d, key, ..args)),
	}
}

// set_language words what the host says from now on in the window's language;
// a locale this build does not know is English.
set_language :: proc(d: ^Desk, c: command.Language) {
	locale := i18n.Locale.English
	if int(c.locale) < len(i18n.Locale) {
		locale = i18n.Locale(c.locale)
	}
	msg.use(d.words, locale)
}

// CATEGORY_NAMES and CATEGORY_WHY are Reclaim's groups as the window names them
// and says why each is safe to delete.
@(rodata)
CATEGORY_NAMES := [reclaim.Category]msg.Msg {
	.Dependencies   = .Reclaim_Dependencies,
	.Build_Output   = .Reclaim_Build_Output,
	.Python         = .Reclaim_Python,
	.Package_Cache  = .Reclaim_Package_Cache,
	.App_Cache      = .Reclaim_App_Cache,
	.Device_Support = .Reclaim_Device_Support,
	.Trash          = .Reclaim_Trash,
}

@(rodata)
CATEGORY_WHY := [reclaim.Category]msg.Msg {
	.Dependencies   = .Why_Dependencies,
	.Build_Output   = .Why_Build_Output,
	.Python         = .Why_Python,
	.Package_Cache  = .Why_Package_Cache,
	.App_Cache      = .Why_App_Cache,
	.Device_Support = .Why_Device_Support,
	.Trash          = .Why_Trash,
}

// FILE_ERRORS say why a change to a file failed, as a clause.
@(rodata)
FILE_ERRORS := [files.Error]msg.Msg {
	.None          = .File_Other,
	.Exists        = .File_Exists,
	.Missing       = .File_Missing,
	.Denied        = .File_Denied,
	.Cross_Device  = .File_Cross_Device,
	.Not_Recycled  = .File_Not_Recycled,
	.Bad_Name      = .File_Bad_Name,
	.Not_Directory = .File_Not_Directory,
	.Partly        = .File_Partly,
	.Mount_Point   = .File_Mount_Point,
	.Not_Yours     = .File_Not_Yours,
	.Unsupported   = .File_Unsupported,
	.Other         = .File_Other,
}

// NAME_FAULTS say why a name cannot be a file's new name, as a clause.
@(rodata)
NAME_FAULTS := [files.Name_Fault]msg.Msg {
	.None     = .File_Bad_Name,
	.Empty    = .Name_Empty,
	.Dot      = .Name_Dot,
	.Slash    = .Name_Slash,
	.Nul      = .Name_Nul,
	.Reserved = .Name_Reserved,
	.Device   = .Name_Device,
	.Trailing = .Name_Trailing,
}

// LICENCE_ERRORS say why a licence was not taken, each naming the product as
// argument 0 where it names it.
@(rodata)
LICENCE_ERRORS := [licence.Error]msg.Msg {
	.None       = .Licence_Not_Valid,
	.No_Key     = .Licence_No_Key,
	.Malformed  = .Licence_Malformed,
	.Version    = .Licence_Newer,
	.Signature  = .Licence_Signature,
	.Terms      = .Licence_Terms_Missing,
	.Unreadable = .Licence_Unreadable,
	.Unwritable = .Licence_Unwritable,
}

// TIER_TITLES are the tiers as the window shows them.
@(rodata)
TIER_TITLES := [licence.Tier]msg.Msg {
	.Personal     = .Tier_Personal,
	.Professional = .Tier_Professional,
	.Organisation = .Tier_Organisation,
}

// REPORT_ERRORS say why a report could not be written, as a clause.
@(rodata)
REPORT_ERRORS := [report.Error]msg.Msg {
	.None         = .Report_Write_Failed,
	.No_Font      = .Report_No_Font,
	.Write_Failed = .Report_Write_Failed,
}
