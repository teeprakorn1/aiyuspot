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
 * "aic8800DC/fmacfw_patch_8800dc_u02.bin") which the kernel mirrors
 * as nested directories under /sys/class/firmware - hence the
 * recursive scan.
 *
 * Served adapters: rt73usb (rt73.bin), aic8800_fdrv (aic8800DC/*).
 * Started by wifi-control.bat before the driver probes.
 */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <limits.h>

#define SYSFW "/sys/class/firmware"
#define LIBFW "/lib/firmware"

/* Locate a firmware file: /lib/firmware/<name>, else search one level
 * of vendor subdirs (e.g. aic8800DC/) for the basename. */
static int find_fw(const char *name, char *out, size_t outsz) {
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

/* Feed one pending firmware request: loading=1 -> data -> loading=0 */
static void serve(const char *reqdir, const char *name) {
    char loading[PATH_MAX], data[PATH_MAX], srcp[PATH_MAX];
    snprintf(loading, sizeof loading, "%s/loading", reqdir);
    snprintf(data, sizeof data, "%s/data", reqdir);

    if (find_fw(name, srcp, sizeof srcp) != 0)
        return; /* no such firmware file - leave request pending */

    FILE *f = fopen(loading, "w");
    if (!f) return;
    fputs("1", f); fclose(f);

    f = fopen(data, "w");
    if (f) {
        FILE *src = fopen(srcp, "rb");
        if (src) {
            char buf[8192];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, src)) > 0)
                fwrite(buf, 1, n, f);
            fclose(src);
        }
        fclose(f);
    }

    f = fopen(loading, "w");
    if (f) { fputs("0", f); fclose(f); }
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

int main(void) {
    for (;;) {
        scan(SYSFW, "");
        usleep(50000); /* 50 ms - keeps CPU idle between polls */
    }
    return 0;
}
