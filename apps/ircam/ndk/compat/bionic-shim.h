/*
 * Bionic-isms the AOSP NDK headers expect but glibc does not provide.
 *
 * We compile against Android's own headers so every struct layout and enum
 * value matches the libcamera2ndk.so on the device exactly. Only one macro is
 * genuinely bionic-specific -- an availability annotation with no effect on
 * code generation -- so defining it away is safe rather than a workaround.
 */
#ifndef IRCAM_BIONIC_SHIM_H
#define IRCAM_BIONIC_SHIM_H
#include <sys/cdefs.h> /* glibc supplies __BEGIN_DECLS / __END_DECLS */
#include <stddef.h>    /* bionic gets size_t transitively; glibc does not */
#include <stdint.h>
#ifndef __INTRODUCED_IN
#define __INTRODUCED_IN(x)
#endif
#endif
