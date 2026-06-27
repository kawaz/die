/* stub.c — Windows CRT text-mode suppression for -n (cat-equivalent) path.
 *
 * On POSIX, _setmode does not exist; this file provides a no-op so the
 * MoonBit extern declaration compiles cleanly on all platforms.
 * On Windows (MSVC / MinGW), _setmode is provided by the CRT and is
 * called via the extern "c" declaration in main.mbt — no stub needed,
 * but this file is still compiled (harmlessly empty on Windows).
 *
 * Design rationale: Only the -n path calls _setmode_binary_fd; the default
 * path intentionally lets CRT text-mode run so \n -> \r\n on Windows, which
 * still satisfies the "cursor-safe" requirement (DR-0006).
 */

#ifndef _WIN32

/* POSIX stub: _setmode is a Windows-only CRT function.
 * Provide a no-op so the MoonBit extern resolves at link time. */
int _setmode(int fd, int mode) {
    (void)fd;
    (void)mode;
    return 0;
}

#endif /* _WIN32 */
