#+build !windows
package scan

// Target resolution needs the OS to say which volume a path lives on and what
// filesystem it runs, so it lands here per platform. Unix answers both from the
// mount table.
resolve :: proc(input: string, allocator := context.allocator) -> (t: Target, err: Error) {
	_, _ = input, allocator
	return {}, .Unsupported_Platform
}
