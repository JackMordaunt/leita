/*
Package home says whose machine this is: the home directory and user id of the
person at the keyboard, which Reclaim's places are relative to.

Under sudo that person is not the process's user, and HOME may be root's own
rather than theirs (sudo -H, or a sudoers always_set_home, puts /var/root there
on macOS), so a whole-drive scan run elevated would look for the Trash and the
caches under a system directory and offer none of them. The rule: in a process
running as root, SUDO_USER, which sudo sets to the invoking user's name, names
the person, and their passwd entry gives the directory and id; otherwise HOME,
which tests and a person point elsewhere on purpose, with the process's own id;
otherwise the process's own passwd entry (sudo(8) sets SUDO_USER as it starts
a command). SUDO_USER is believed only as root: anyone can set it, and a process
not running as root that believed it would look for another user's places. Run
as root, it is trusted as said. Windows has no sudo: the profile directory, and
the account's SID string.
*/
package home

// User is the person whose places Reclaim offers. uid is the user id as a
// decimal string or a Windows SID string; "" where there is none.
User :: struct {
	dir: string,
	uid: string,
}
