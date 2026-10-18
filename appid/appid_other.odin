#+build !windows
package leita_appid

// set does nothing off Windows, where there is no AppUserModelID, and says so.
set :: proc() -> bool {
	return false
}
