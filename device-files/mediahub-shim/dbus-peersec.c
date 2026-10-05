/*
 * dbus-peersec.so - LD_PRELOAD shim for the SESSION dbus-daemon.
 *
 * WHAT THIS IS: a WORKAROUND, labelled as one deliberately.
 *
 * WHY
 * media-hub identifies D-Bus clients by the bus's LinuxSecurityLabel, which
 * dbus-daemon reads with getsockopt(SO_PEERSEC). On this port that value is
 * never usable and media-hub dies on EVERY OpenUri, so nothing plays:
 *   - SELinux (flashed image): every Ubuntu-side process is in the unlabelled
 *     `kernel` domain -> label "kernel" -> media-hub cannot parse it as
 *     pkgname_appname_version -> dereferences an uninitialised member -> SIGSEGV.
 *   - AppArmor (halium-boot-apparmor.img): this kernel never assigns
 *     aa_sk_ctx->peer, so SO_PEERSEC always fails -> no label at all ->
 *     media-hub throws "Context cannot be created for empty name".
 * Proof for both is in BUILD_NOTES.
 *
 * Interposing media-hub's own libapparmor call does NOT work: aa_splitcon() is
 * verified (with a syscall-marker build) to run AFTER the Context is already
 * constructed from the raw label. The label has to be corrected at its source.
 *
 * WHAT IT DOES
 * Reports "unconfined" for SO_PEERSEC. Every other getsockopt is passed through
 * untouched via the raw syscall.
 *
 * IS IT HONEST? On a system with no working confinement every process really is
 * unconfined, so the reported value is semantically true. What makes it a
 * workaround is the mechanism, and that it removes media-hub's per-app access
 * control -- which on this port never functioned, it only crashed.
 *
 * PROPER FIX: (a) backport Ubuntu's out-of-tree AppArmor patchset so SO_PEERSEC
 * reports real labels, or (b) fix media-hub upstream to treat an unparseable or
 * empty label as unconfined rather than crashing.
 *
 * TO REMOVE: delete the dbus.service drop-in and reboot.
 *
 * Built -nostdlib: no libc at link time. __errno_location is resolved at load
 * time from the libc that dbus-daemon already has mapped.
 */

#define SOL_SOCKET_  1
#define SO_PEERSEC_  31
#define NR_getsockopt 209   /* aarch64 */

typedef unsigned int socklen_t_;

extern int *__errno_location(void);

static const char kUnconfined[] = "unconfined";

static long raw_getsockopt(int fd, int level, int optname,
                           void *optval, socklen_t_ *optlen)
{
	register long x8 __asm__("x8") = NR_getsockopt;
	register long x0 __asm__("x0") = fd;
	register long x1 __asm__("x1") = level;
	register long x2 __asm__("x2") = optname;
	register long x3 __asm__("x3") = (long)optval;
	register long x4 __asm__("x4") = (long)optlen;
	__asm__ volatile("svc #0"
	                 : "+r"(x0)
	                 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
	                 : "memory", "cc");
	return x0;
}

int getsockopt(int fd, int level, int optname, void *optval, socklen_t_ *optlen);

int getsockopt(int fd, int level, int optname, void *optval, socklen_t_ *optlen)
{
	if (level == SOL_SOCKET_ && optname == SO_PEERSEC_ && optval && optlen) {
		const unsigned int need = sizeof(kUnconfined);   /* includes NUL */
		if (*optlen >= need) {
			char *dst = (char *)optval;
			unsigned int i;
			for (i = 0; i < need; i++)
				dst[i] = kUnconfined[i];
			*optlen = need;      /* SELinux also counts the NUL */
			return 0;
		}
		/* Buffer too small: fall through to the kernel so the caller sees
		 * exactly the error it would normally get. */
	}

	long r = raw_getsockopt(fd, level, optname, optval, optlen);
	if (r < 0) {
		*__errno_location() = (int)-r;
		return -1;
	}
	return (int)r;
}
