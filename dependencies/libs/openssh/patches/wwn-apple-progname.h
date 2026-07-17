/* App Store Connect rejects Mach-O symbol ___progname (altool code 11).
 *
 * On Darwin, the C identifier __progname is emitted as ___progname (extra
 * underscore ABI prefix). OpenSSH's portable char *__progname therefore
 * collides with the private libc symbol name even when HAVE___PROGNAME is off.
 *
 * Redirect every __progname reference to a Wawona-owned identifier. The
 * definition lives in openbsd-compat/bsd-misc.c (char *__progname →
 * char *wwn_ssh_progname after this macro). */
#ifndef WWN_APPLE_PROGNAME_H
#define WWN_APPLE_PROGNAME_H

#ifdef __APPLE__
#ifdef __progname
#undef __progname
#endif
#define __progname wwn_ssh_progname
#endif

#endif /* WWN_APPLE_PROGNAME_H */
