/*
 * stub.c — portable C stubs for die (MoonBit native backend).
 *
 * On Windows, _setmode() is provided by the CRT (<io.h> / <fcntl.h>).
 * On POSIX systems the symbol does not exist, so we provide a no-op stub
 * to satisfy the linker when the MoonBit code calls it conditionally.
 */

#ifndef _WIN32
/* Provide a no-op _setmode stub on non-Windows platforms.
 * The MoonBit code guards the call with is_windows_host(), so this
 * path is never reached at runtime; it only satisfies the linker. */
int _setmode(int fd, int mode) {
    (void)fd;
    (void)mode;
    return 0;
}
#endif
