/*
 * stub.c — portable C stubs for die (MoonBit native backend).
 *
 * On Windows, _setmode() is provided by the CRT (<io.h> / <fcntl.h>).
 * On POSIX systems the symbol does not exist, so we provide a no-op stub
 * to satisfy the linker when the MoonBit code calls it conditionally.
 */

#include <stdlib.h>
#include <string.h>

/*
 * die_is_windows_runtime: returns 1 if running on Windows NT, 0 otherwise.
 *
 * We wrap getenv() in a C helper to avoid MoonBit's codegen emitting
 * `int32_t getenv(moonbit_bytes_t);` which conflicts with stdlib.h's
 * `char *getenv(const char *)` on glibc/gcc (ubuntu CI).
 */
int die_is_windows_runtime(void) {
    const char *v = getenv("OS");
    return (v != NULL && strcmp(v, "Windows_NT") == 0) ? 1 : 0;
}

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
