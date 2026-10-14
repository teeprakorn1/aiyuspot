/*
 * fwserve - sysfs firmware fallback for rt73.bin under WSL2.
 *
 * WSL2 kernels cannot fetch firmware from userspace. With
 * force_sysfs_fallback=1 the kernel creates
 * /sys/class/firmware/rt73.bin/ and waits; this daemon feeds it
 * /lib/firmware/rt73.bin. Started by wifi-control.bat before
 * modprobe rt73usb.
 */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char loading[256], data[256];
    struct stat st;
    FILE *f, *src;
    char buf[4096];
    size_t n;

    while (1) {
        if (stat("/sys/class/firmware/rt73.bin", &st) == 0 && S_ISDIR(st.st_mode)) {
            snprintf(loading, sizeof(loading), "/sys/class/firmware/rt73.bin/loading");
            snprintf(data, sizeof(data), "/sys/class/firmware/rt73.bin/data");
            if ((f = fopen(loading, "w"))) { fputs("1\n", f); fclose(f); }
            if ((f = fopen(data, "w"))) {
                if ((src = fopen("/lib/firmware/rt73.bin", "r"))) {
                    while ((n = fread(buf, 1, sizeof buf, src)) > 0) fwrite(buf, 1, n, f);
                    fclose(src);
                }
                fclose(f);
            }
            if ((f = fopen(loading, "w"))) { fputs("0\n", f); fclose(f); }
        }
        usleep(50000);
    }
    return 0;
}
