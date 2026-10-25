#+build windows
package netfault

import "core:net"
import win "core:sys/windows"

// reset_on_close makes the close of socket a reset: SO_LINGER on, for no
// time, drops what is unsent and sends RST in place of FIN.
@(private)
reset_on_close :: proc(socket: net.TCP_Socket) {
	l := win.LINGER {
		l_onoff  = 1,
		l_linger = 0,
	}
	win.setsockopt(win.SOCKET(uintptr(socket)), win.SOL_SOCKET, win.SO_LINGER, &l, size_of(l))
}
