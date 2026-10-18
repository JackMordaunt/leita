/*
Package appid names Leita to the operating system's shell, which groups
windows, notifications and pinned shortcuts by an application's id.

On Windows that is the AppUserModelID. A toast is shown only for an
application Windows knows by one, and knows one by a Start menu shortcut that
carries it, which the installer makes (tools/windows/leita.iss). A program
that sets none is given one by the shell, which is not the shortcut's, so each
binary sets ID at its start, as Microsoft's "Application User Model IDs
(AppUserModelIDs)" and SetCurrentProcessExplicitAppUserModelID describe.
Elsewhere the call does nothing.
*/
package leita_appid

// ID is Leita's AppUserModelID: the company, then the product, as Microsoft's
// "Application User Model IDs" asks (CompanyName.ProductName). It is also named
// in tools/windows/leita.iss and alert/notify.odin, and the three agree.
ID :: "Librium.Leita"
