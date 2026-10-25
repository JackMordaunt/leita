#+build linux, darwin, freebsd, openbsd, netbsd
package netfault

import "core:net"
import "core:sys/posix"

// reset_on_close makes the close of socket a reset: SO_LINGER on, for no
// time, drops what is unsent and sends RST in place of FIN.
@(private)
reset_on_close :: proc(socket: net.TCP_Socket) {
	l := posix.linger {
		l_onoff  = 1,
		l_linger = 0,
	}
	posix.setsockopt(posix.FD(socket), posix.SOL_SOCKET, .LINGER, &l, size_of(l))
}
