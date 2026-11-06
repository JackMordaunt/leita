package leita_cli

import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../monitor"
import "../settings"

// Configuring an export is Pro. Inspecting and disabling it remain available
// after the evaluation, without touching the destination or the scheduler.
@(private)
monitor_metrics :: proc(c: Monitor_Context, args: []string, w: io.Writer) -> int {
	if len(args) > 1 {
		monitor_errorf(c, w, "metrics takes one PATH.prom, off, or no argument")
		return monitor.EXIT_FAILED
	}
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		monitor_print_usage(c, w)
		return 0
	}
	show := len(args) == 0
	off := !show && args[0] == "off"
	if !show && !off && !c.unlocked {
		monitor_errorf(c, w, MONITOR_LOCKED)
		return monitor.EXIT_FAILED
	}
	path := ""
	if !show && !off {
		if !strings.has_suffix(args[0], ".prom") ||
		   len(args[0]) > 4096 ||
		   strings.contains_any(args[0], "\x00\r\n") {
			monitor_errorf(c, w, "metrics needs a path ending in .prom, without line breaks")
			return monitor.EXIT_FAILED
		}
		err: os.Error
		directory: string
		directory, err = os.get_absolute_path(filepath.dir(args[0]), context.temp_allocator)
		if err ==
		   nil {path, _ = filepath.join({directory, filepath.base(args[0])}, context.temp_allocator)}
		if err != nil {
			monitor_errorf(c, w, "cannot resolve metrics path: %v", err)
			return monitor.EXIT_FAILED
		}
	}
	st: settings.Store
	if !monitor_open_settings(c, &st, w, write = !show) {return monitor.EXIT_FAILED}
	defer settings.close(&st)
	// A running monitor owns its destination/cache snapshot until publication.
	// Serialize mutations with that entire run; inspecting settings stays free.
	l: monitor.Lock
	locked := false
	defer if locked {monitor.unlock(&l)}
	if !show {
		result: monitor.Lock_Result
		l, result = monitor.lock(c.paths.lock)
		switch result {
		case .Taken:
			locked = true
		case .Held:
			monitor_errorf(
				c,
				w,
				"a monitoring run is in progress; change metrics after it finishes",
			)
			return monitor.EXIT_FAILED
		case .Failed:
			monitor_errorf(c, w, "cannot lock monitoring settings at %s", c.paths.lock)
			return monitor.EXIT_FAILED
		}
	}
	if show {
		problem: string
		path, problem = monitor.metrics_setting(&st, monitor.METRICS_PATH_KEY)
		if problem != "" {
			monitor_errorf(c, w, "cannot read metrics settings: %s", problem)
			return monitor.EXIT_FAILED
		}
	} else if problem := monitor.metrics_configure(&st, path); problem != "" {
		monitor_errorf(c, w, "cannot save metrics settings: %s", problem)
		return monitor.EXIT_FAILED
	}

	if path == "" {
		monitor_notef(c, w, "metrics output is off; any previously written file is left in place")
	} else {
		monitor_notef(c, w, "metrics output: %s (includes local path labels)", path)
	}
	return 0
}
