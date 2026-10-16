/*
 * fwserve - sysfs firmware fallback for WSL2.
 *
 * WSL2 kernels cannot fetch firmware from userspace: the firmware
 * request uevent is never delivered, so request_firmware() fails even
 * when the file exists under /lib/firmware. With
 * /proc/sys/kernel/firmware_config/force_sysfs_fallback=1 the kernel
 * instead creates /sys/class/firmware/<fw_name>/ and waits; this
 * daemon polls that tree and feeds each pending request the matching
 * file from /lib/firmware/<fw_name>.
 *
 * Firmware names may contain a subdirectory (e.g.
 * "rtlwifi/rtl8723bu_nic.bin"). The kernel names each request dir
 * after the full firmware name with '/' mangled to '!' by
 * kobject_set_name() - so /sys/class/firmware/rtlwifi!rtl8723bu_nic.bin/
 * is a single flat directory, and serve() must decode '!' back to '/'
 * before looking the file up under /lib/firmware.
 *
 * Served adapters: rt73usb (rt73.bin), aic8800_fdrv (aic8800DC blobs),
 * rtl8xxxu (rtlwifi/rtl8723bu_nic.bin).
 * Started by wifi-control.bat before the driver probes.
 */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <signal.h>
#include <limits.h>

#ifndef SYSFW
#define SYSFW "/sys/class/firmware"
#endif
#ifndef LIBFW
#define LIBFW "/lib/firmware"
#endif

/* Locate a firmware file: /lib/firmware/<name>, else search one level
 * of vendor subdirs (e.g. rtlwifi/) for the basename. The name arrives
 * already decoded ('!' -> '/'), so it may contain real slashes. */
static int find_fw(const char *name, char *out, size_t outsz) {
    if (strstr(name, "..")) return -1;   /* never serve a traversal */
    struct stat st;
    snprintf(out, outsz, LIBFW "/%s", name);
    if (stat(out, &st) == 0) return 0;

    const char *base = strrchr(name, '/');
    base = base ? base + 1 : name;
    DIR *d = opendir(LIBFW);
    if (!d) return -1;
    struct dirent *e;
    int rc = -1;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(out, outsz, LIBFW "/%s/%s", e->d_name, base);
        if (stat(out, &st) == 0) { rc = 0; break; }
    }
    closedir(d);
    return rc;
}

/* Path of the in-flight request's "loading" node. If the daemon is
 * killed mid-serve, the signal handler aborts the request so the kernel
 * does not wait out the firmware timeout on a dead helper. */
static char inflight_loading[PATH_MAX];
static volatile sig_atomic_t inflight = 0;

static void on_sig(int sig) {
    (void)sig;
    if (inflight) {
        int fd = open(inflight_loading, O_WRONLY);
        if (fd >= 0) { (void)write(fd, "-1", 2); close(fd); }
    }
    _exit(1);
}

/* Feed one pending firmware request: loading=1 -> data -> loading=0.
 * The sysfs request dir is named with '/' mangled to '!'; decode it
 * back so subdirectory firmware (rtlwifi/x.bin, aic8800DC/x.bin) can
 * be found on disk. */
static void serve(const char *reqdir, const char *name) {
    char loading[PATH_MAX], data[PATH_MAX], srcp[PATH_MAX], dec[PATH_MAX];
    snprintf(loading, sizeof loading, "%s/loading", reqdir);
    snprintf(data, sizeof data, "%s/data", reqdir);

    snprintf(dec, sizeof dec, "%s", name);
    for (char *c = dec; *c; ++c)
        if (*c == '!') *c = '/';

    if (find_fw(dec, srcp, sizeof srcp) != 0) {
        fprintf(stderr, "fwserve: %s - no firmware blob under %s\n", dec, LIBFW);
        return; /* leave the request pending for something else to serve */
    }

    FILE *f = fopen(loading, "w");
    if (!f) { fprintf(stderr, "fwserve: %s - cannot open %s\n", dec, loading); return; }
    fputs("1", f); fclose(f);
    snprintf(inflight_loading, sizeof inflight_loading, "%s", loading);
    inflight = 1;

    int ok = 0;
    f = fopen(data, "w");
    if (f) {
        FILE *src = fopen(srcp, "rb");
        if (src) {
            char buf[8192];
            size_t n;
            ok = 1;
            while ((n = fread(buf, 1, sizeof buf, src)) > 0)
                if (fwrite(buf, 1, n, f) != n) { ok = 0; break; }
            /* A read error is not EOF: without this check a truncated
             * source would be committed as a complete firmware blob. */
            if (ferror(src)) ok = 0;
            fclose(src);
        } else {
            fprintf(stderr, "fwserve: %s - cannot open %s\n", dec, srcp);
        }
        /* Buffered writes can surface their error only at close. */
        if (fclose(f) != 0) ok = 0;
    } else {
        fprintf(stderr, "fwserve: %s - cannot open %s\n", dec, data);
    }

    /* On any failure write -1 to abort the request - otherwise the
     * kernel would commit an empty blob and the probe fails oddly. */
    f = fopen(loading, "w");
    if (f) { fputs(ok ? "0" : "-1", f); fclose(f); }
    inflight = 0;
    fprintf(stderr, "fwserve: %s %s\n", dec, ok ? "served" : "aborted");
}

/* A request dir contains a "loading" node. */
static int is_request(const char *path) {
    char p[PATH_MAX];
    struct stat st;
    snprintf(p, sizeof p, "%s/loading", path);
    return stat(p, &st) == 0;
}

/* Walk SYSFW; rel is the firmware name built from nested dirs. */
static void scan(const char *path, const char *rel) {
    DIR *d = opendir(path);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char child[PATH_MAX], name[PATH_MAX];
        struct stat st;
        snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        snprintf(name, sizeof name, "%s%s%s", rel, rel[0] ? "/" : "", e->d_name);
        if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        if (is_request(child))
            serve(child, name);
        else
            scan(child, name);
    }
    closedir(d);
}

#ifndef FWSERVE_NO_MAIN
int main(void) {
    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);
    fprintf(stderr, "fwserve: watching %s -> %s\n", SYSFW, LIBFW);
    for (;;) {
        scan(SYSFW, "");
        usleep(50000); /* 50 ms - keeps CPU idle between polls */
    }
    return 0;
}
#endif /* FWSERVE_NO_MAIN */
