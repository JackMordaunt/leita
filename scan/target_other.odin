#+build !windows
package scan

// Target resolution needs the OS to say which volume a path lives on and what
// filesystem it runs, so it lands here per platform. Unix answers both from the
// mount table.
resolve :: proc(input: string, allocator := context.allocator) -> (t: Target, err: Error) {
	_, _ = input, allocator
	return {}, .Unsupported_Platform
}

/*
Whether this process can open a raw volume handle.

No target resolves on this platform yet, so nothing here can reach a volume however
this answers. A platform that implements `resolve` implements this beside it: on unix
raw device access is a matter of file permissions rather than a token, so the honest
answer is whether the device opens.
*/
elevated :: proc() -> bool {
	return false
}
