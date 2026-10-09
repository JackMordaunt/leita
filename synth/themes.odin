package synth

/*
A theme is what a part of the disk looks like below the names laid out for it:
what its files are called and how big they run, and how its folders branch.
*/
@(private)
Theme :: struct {
	exts:         []string, // one is drawn for each file; "" for none
	words:        []string,
	style:        Style,
	folders:      []string,
	folder_style: Style,
	folder_ext:   string,
	child:        Theme_Id, // its subfolders' theme; .Same for its own
	typical:      f64, // a file's usual size in bytes
	sigma:        f64, // how far sizes spread from it
	depth:        int, // subfolders branch above this depth and not below it
	subs:         [2]int, // how many subfolders a folder branches into, least and most
	most:         int, // the most files a folder holds
	share:        [2]f64, // the part of a folder's bytes in its own files, least and most
}

@(private)
Theme_Id :: enum u8 {
	Same,
	Docs,
	Binaries,
	Bundles,
	Frameworks,
	Libraries,
	Headers,
	Resources,
	Assets,
	Asset_Blobs,
	Fonts,
	Cache,
	Support,
	Loops,
	Logs,
	Share,
	Screens,
	Source,
	Scripts,
	Python,
	Rust_Target,
	Hooks,
	Objects,
	Mail,
	Photos,
	Buckets,
	Thumbs,
	Sim_Data,
	Devices,
	Backup,
	Backup_Shards,
	Derived,
	Xcode_Build,
	Artists,
	Albums,
	Tracks,
	Models,
	Model_Files,
}

// THEMES finds a theme by its id. Each is a global of its own: as one table of
// them all, Odin dev-2026-10 (19cbd8650) warned that its 5776-byte initialisation
// was not constant and "might cause problems with LLVM".
@(private)
THEMES := [Theme_Id]^Theme {
	.Same          = &SAME_THEME,
	.Docs          = &DOCS_THEME,
	.Binaries      = &BINARIES_THEME,
	.Bundles       = &BUNDLES_THEME,
	.Frameworks    = &FRAMEWORKS_THEME,
	.Libraries     = &LIBRARIES_THEME,
	.Headers       = &HEADERS_THEME,
	.Resources     = &RESOURCES_THEME,
	.Assets        = &ASSETS_THEME,
	.Asset_Blobs   = &ASSET_BLOBS_THEME,
	.Fonts         = &FONTS_THEME,
	.Cache         = &CACHE_THEME,
	.Support       = &SUPPORT_THEME,
	.Loops         = &LOOPS_THEME,
	.Logs          = &LOGS_THEME,
	.Share         = &SHARE_THEME,
	.Screens       = &SCREENS_THEME,
	.Source        = &SOURCE_THEME,
	.Scripts       = &SCRIPTS_THEME,
	.Python        = &PYTHON_THEME,
	.Rust_Target   = &RUST_TARGET_THEME,
	.Hooks         = &HOOKS_THEME,
	.Objects       = &OBJECTS_THEME,
	.Mail          = &MAIL_THEME,
	.Photos        = &PHOTOS_THEME,
	.Buckets       = &BUCKETS_THEME,
	.Thumbs        = &THUMBS_THEME,
	.Sim_Data      = &SIM_DATA_THEME,
	.Devices       = &DEVICES_THEME,
	.Backup        = &BACKUP_THEME,
	.Backup_Shards = &BACKUP_SHARDS_THEME,
	.Derived       = &DERIVED_THEME,
	.Xcode_Build   = &XCODE_BUILD_THEME,
	.Artists       = &ARTISTS_THEME,
	.Albums        = &ALBUMS_THEME,
	.Tracks        = &TRACKS_THEME,
	.Models        = &MODELS_THEME,
	.Model_Files   = &MODEL_FILES_THEME,
}

@(private)
SAME_THEME := Theme{}

@(private)
DOCS_THEME := Theme {
	exts    = {"pdf", "pdf", "docx", "xlsx", "pages", "key", "txt", "md", "csv", "png", "jpg"},
	words   = DOC_WORDS[:],
	folders = DOC_FOLDERS[:],
	typical = 700 * KiB,
	sigma   = 1.4,
	depth   = 3,
	subs    = {2, 7},
	most    = 60,
	share   = {0.2, 0.5},
}

@(private)
BINARIES_THEME := Theme {
	exts    = {""},
	words   = BIN_WORDS[:],
	typical = 1.8 * MiB,
	sigma   = 1.1,
	most    = 400,
	share   = {1, 1},
}

@(private)
BUNDLES_THEME := Theme {
	exts       = {"plist"},
	words      = {"Info"},
	folders    = APP_WORDS[:],
	folder_ext = "app",
	child      = .Resources,
	typical    = 400 * KiB,
	depth      = 1,
	subs       = {3, 12},
	most       = 1,
	share      = {0, 0.02},
}

@(private)
FRAMEWORKS_THEME := Theme {
	exts       = {"plist"},
	words      = {"Info"},
	folders    = FRAMEWORK_WORDS[:],
	folder_ext = "framework",
	child      = .Libraries,
	typical    = 4 * KiB,
	depth      = 1,
	subs       = {12, 60},
	most       = 1,
	share      = {0, 0.01},
}

@(private)
LIBRARIES_THEME := Theme {
	exts    = {"dylib", "dylib", "a", "so", "", "tbd", "plist"},
	words   = LIB_WORDS[:],
	folders = LIB_FOLDERS[:],
	typical = 2.4 * MiB,
	sigma   = 1.5,
	depth   = 3,
	subs    = {2, 6},
	most    = 120,
	share   = {0.3, 0.7},
}

@(private)
HEADERS_THEME := Theme {
	exts    = {"h", "h", "hpp", "inc"},
	words   = CODE_WORDS[:],
	folders = LIB_WORDS[:],
	typical = 14 * KiB,
	sigma   = 1.0,
	depth   = 1,
	subs    = {1, 4},
	most    = 120,
	share   = {0.4, 0.8},
}

@(private)
RESOURCES_THEME := Theme {
	exts    = {"png", "png", "car", "nib", "icns", "strings", "plist", "json", "tiff"},
	words   = UI_WORDS[:],
	folders = LPROJ[:],
	typical = 160 * KiB,
	sigma   = 1.6,
	depth   = 1,
	subs    = {4, 30},
	most    = 300,
	share   = {0.6, 0.9},
}

@(private)
ASSETS_THEME := Theme {
	exts    = {"plist"},
	words   = {"catalog"},
	folders = ASSET_CLASSES[:],
	child   = .Asset_Blobs,
	typical = 50 * KiB,
	depth   = 1,
	subs    = {5, 9},
	most    = 1,
	share   = {0, 0.01},
}

@(private)
ASSET_BLOBS_THEME := Theme {
	exts         = {"dmg", "dmg", "pkg"},
	style        = .Part,
	folder_style = .Hex,
	folder_ext   = "asset",
	typical      = 700 * MiB,
	sigma        = 0.7,
	depth        = 2,
	subs         = {2, 6},
	most         = 4,
	share        = {0, 0.02},
}

@(private)
FONTS_THEME := Theme {
	exts    = {"ttf", "otf", "ttc"},
	words   = FONT_WORDS[:],
	typical = 450 * KiB,
	sigma   = 1.0,
	most    = 300,
	share   = {1, 1},
}

@(private)
CACHE_THEME := Theme {
	exts    = {"", "", "", "db", "json"},
	style   = .Hex,
	folders = CACHE_FOLDERS[:],
	typical = 180 * KiB,
	sigma   = 1.5,
	depth   = 2,
	subs    = {2, 8},
	most    = 400,
	share   = {0.3, 0.8},
}

@(private)
SUPPORT_THEME := Theme {
	exts    = {"db", "json", "ldb", "log", "sqlite", "plist"},
	words   = SUPPORT_WORDS[:],
	folders = SUPPORT_FOLDERS[:],
	typical = 600 * KiB,
	sigma   = 1.6,
	depth   = 3,
	subs    = {2, 8},
	most    = 80,
	share   = {0.2, 0.5},
}

@(private)
LOOPS_THEME := Theme {
	exts    = {"caf", "aif", "wav"},
	words   = LOOP_WORDS[:],
	folders = LOOP_FOLDERS[:],
	typical = 1.8 * MiB,
	sigma   = 0.9,
	depth   = 2,
	subs    = {2, 8},
	most    = 200,
	share   = {0.4, 0.8},
}

@(private)
LOGS_THEME := Theme {
	exts    = {"log", "log", "gz", "ips", "diag"},
	words   = LOG_WORDS[:],
	folders = LOG_FOLDERS[:],
	typical = 260 * KiB,
	sigma   = 1.3,
	depth   = 1,
	subs    = {2, 8},
	most    = 150,
	share   = {0.3, 0.7},
}

@(private)
SHARE_THEME := Theme {
	exts    = {"1", "gz", "txt", "plist", "html", "json", "xml"},
	words   = SHARE_WORDS[:],
	folders = SHARE_FOLDERS[:],
	typical = 18 * KiB,
	sigma   = 1.3,
	depth   = 3,
	subs    = {2, 10},
	most    = 200,
	share   = {0.2, 0.5},
}

@(private)
SCREENS_THEME := Theme {
	exts    = {"png", "png", "png", "mov"},
	style   = .Screenshot,
	typical = 1.6 * MiB,
	sigma   = 0.7,
	most    = 2000,
	share   = {1, 1},
}

@(private)
SOURCE_THEME := Theme {
	exts    = {"go", "ts", "tsx", "rs", "py", "md", "json", "yaml", "css", "toml"},
	words   = CODE_WORDS[:],
	folders = SRC_FOLDERS[:],
	typical = 9 * KiB,
	sigma   = 1.1,
	depth   = 4,
	subs    = {2, 7},
	most    = 40,
	share   = {0.2, 0.5},
}

@(private)
SCRIPTS_THEME := Theme {
	exts    = {"js", "js", "mjs", "cjs", "map", "d.ts", "json", "md"},
	words   = CODE_WORDS[:],
	folders = JS_FOLDERS[:],
	typical = 16 * KiB,
	sigma   = 1.3,
	depth   = 3,
	subs    = {2, 6},
	most    = 60,
	share   = {0.3, 0.6},
}

@(private)
PYTHON_THEME := Theme {
	exts    = {"py", "py", "pyc", "so", "pyi", "txt", "json"},
	words   = CODE_WORDS[:],
	folders = PY_FOLDERS[:],
	typical = 40 * KiB,
	sigma   = 1.9,
	depth   = 5,
	subs    = {2, 8},
	most    = 80,
	share   = {0.2, 0.5},
}

@(private)
RUST_TARGET_THEME := Theme {
	exts    = {"rlib", "rmeta", "d", "o", ""},
	words   = CRATES[:],
	style   = .Crate,
	folders = RUST_FOLDERS[:],
	typical = 1.6 * MiB,
	sigma   = 1.6,
	depth   = 2,
	subs    = {2, 4},
	most    = 400,
	share   = {0.05, 0.2},
}

@(private)
HOOKS_THEME := Theme {
	exts    = {""},
	words   = HOOKS[:],
	typical = 2 * KiB,
	sigma   = 0.6,
	most    = 14,
	share   = {1, 1},
}

@(private)
OBJECTS_THEME := Theme {
	exts         = {""},
	style        = .Hex,
	folder_style = .Hex2,
	typical      = 3 * KiB,
	sigma        = 1.2,
	depth        = 1,
	subs         = {40, 64},
	most         = 300,
	share        = {0, 0.02},
}

@(private)
MAIL_THEME := Theme {
	exts    = {"emlx", "emlx", "emlx", "partial.emlx"},
	style   = .Hex,
	folders = MAIL_FOLDERS[:],
	typical = 60 * KiB,
	sigma   = 1.4,
	depth   = 3,
	subs    = {2, 6},
	most    = 600,
	share   = {0.2, 0.6},
}

@(private)
PHOTOS_THEME := Theme {
	exts    = {"heic", "heic", "heic", "jpg", "png", "mov"},
	style   = .Uuid,
	typical = 3.2 * MiB,
	sigma   = 0.6,
	most    = 4000,
	share   = {1, 1},
}

@(private)
BUCKETS_THEME := Theme {
	folder_style = .Digit,
	child        = .Photos,
	typical      = 3.2 * MiB,
	depth        = 1,
	subs         = {16, 16},
	share        = {0, 0},
}

@(private)
THUMBS_THEME := Theme {
	exts         = {"jpeg"},
	style        = .Uuid,
	folder_style = .Digit,
	typical      = 180 * KiB,
	sigma        = 0.5,
	depth        = 1,
	subs         = {16, 16},
	most         = 5000,
	share        = {0, 0},
}

@(private)
SIM_DATA_THEME := Theme {
	exts    = {"db", "plist", "sqlite", "png", "json", "dat", "sqlite-wal"},
	words   = SIM_WORDS[:],
	folders = SIM_FOLDERS[:],
	typical = 220 * KiB,
	sigma   = 1.6,
	depth   = 4,
	subs    = {2, 6},
	most    = 120,
	share   = {0.2, 0.5},
}

@(private)
DEVICES_THEME := Theme {
	exts         = {"plist"},
	words        = {"device_set"},
	folder_style = .Uuid,
	child        = .Sim_Data,
	typical      = 2 * KiB,
	depth        = 1,
	subs         = {6, 14},
	most         = 1,
	share        = {0, 0.01},
}

@(private)
BACKUP_THEME := Theme {
	exts         = {"plist"},
	words        = {"Manifest"},
	folder_style = .Uuid,
	child        = .Backup_Shards,
	typical      = 900 * KiB,
	depth        = 1,
	subs         = {1, 2},
	most         = 1,
	share        = {0, 0.001},
}

@(private)
BACKUP_SHARDS_THEME := Theme {
	exts         = {""},
	style        = .Hex,
	folder_style = .Hex2,
	typical      = 900 * KiB,
	sigma        = 1.8,
	depth        = 2,
	subs         = {48, 64},
	most         = 400,
	share        = {0, 0.01},
}

@(private)
DERIVED_THEME := Theme {
	folders = DERIVED[:],
	child   = .Xcode_Build,
	typical = 500 * KiB,
	depth   = 1,
	subs    = {4, 9},
	share   = {0, 0},
}

@(private)
XCODE_BUILD_THEME := Theme {
	exts    = {"o", "o", "swiftmodule", "d", "swiftdeps", "dia", "json", "a"},
	words   = CODE_WORDS[:],
	folders = XCODE_FOLDERS[:],
	typical = 500 * KiB,
	sigma   = 1.5,
	depth   = 5,
	subs    = {2, 6},
	most    = 150,
	share   = {0.1, 0.4},
}

@(private)
ARTISTS_THEME := Theme {
	folders = ARTISTS[:],
	child   = .Albums,
	typical = 8 * MiB,
	depth   = 1,
	subs    = {14, 26},
	share   = {0, 0},
}

@(private)
ALBUMS_THEME := Theme {
	exts    = {"jpg"},
	words   = {"cover"},
	folders = ALBUMS[:],
	child   = .Tracks,
	typical = 300 * KiB,
	depth   = 2,
	subs    = {1, 3},
	most    = 1,
	share   = {0, 0.01},
}

@(private)
TRACKS_THEME := Theme {
	exts    = {"m4a"},
	words   = TRACKS[:],
	style   = .Track,
	typical = 8 * MiB,
	sigma   = 0.4,
	most    = 18,
	share   = {1, 1},
}

@(private)
MODELS_THEME := Theme {
	folders = MODELS[:],
	child   = .Model_Files,
	typical = 350 * MiB,
	depth   = 1,
	subs    = {3, 6},
	share   = {0, 0},
}

@(private)
MODEL_FILES_THEME := Theme {
	exts    = {"safetensors", "safetensors", "bin", "json"},
	words   = MODEL_WORDS[:],
	typical = 350 * MiB,
	sigma   = 1.8,
	most    = 12,
	share   = {1, 1},
}
