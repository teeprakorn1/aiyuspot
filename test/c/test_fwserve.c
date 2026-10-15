/* fwserve unit test - includes fwserve.c with SYSFW/LIBFW redirected to
 * fixture dirs so no real sysfs is touched.
 *
 *   gcc -DFWSERVE_NO_MAIN -DSYSFW='"/tmp/fwtest_sysfw"' \
 *       -DLIBFW='"/tmp/fwtest_libfw"' -o test_fwserve test_fwserve.c
 *   ./test_fwserve
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void write_file(const char *path, const char *data) {
    FILE *f = fopen(path, "w");
    assert(f);
    fputs(data, f);
    fclose(f);
}

static int read_int(const char *path) {
    FILE *f = fopen(path, "r");
    assert(f);
    int v = 0;
    assert(fscanf(f, "%d", &v) == 1);
    fclose(f);
    return v;
}

/* Fake a pending firmware request dir: <sysfw>/<rel>/{loading,data,device} */
static void mk_request(const char *rel, const char *fwname) {
    char d[512], p[512];
    snprintf(d, sizeof d, "%s/%s", SYSFW, rel);
    mkdir(d, 0755);
    snprintf(p, sizeof p, "%s/loading", d); write_file(p, "0");
    snprintf(p, sizeof p, "%s/data", d);    write_file(p, "");
    snprintf(p, sizeof p, "%s/device", d);  write_file(p, fwname);
}

static int passed, failed;
#define CHECK(cond, msg) do { \
    if (cond) { passed++; printf("  PASS  %s\n", msg); } \
    else      { failed++; printf("  FAIL  %s\n", msg); } \
} while (0)

#define FWSERVE_NO_MAIN 1
#include "../../fwserve/fwserve.c"

int main(void) {
    char p[512];

    /* Case 1: firmware exists -> bytes served, loading=0 */
    snprintf(p, sizeof p, "%s/rt73.bin", LIBFW);
    write_file(p, "FAKEFW123");
    mk_request("dev1", "rt73.bin");
    snprintf(p, sizeof p, "%s/dev1", SYSFW);
    serve(p, "rt73.bin");

    char data_p[512], load_p[512], buf[64];
    snprintf(data_p, sizeof data_p, "%s/dev1/data", SYSFW);
    snprintf(load_p, sizeof load_p, "%s/dev1/loading", SYSFW);
    FILE *f = fopen(data_p, "rb");
    assert(f);
    memset(buf, 0, sizeof buf);
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    CHECK(n == 9 && memcmp(buf, "FAKEFW123", 9) == 0, "firmware bytes written");
    CHECK(read_int(load_p) == 0, "loading=0 after success");

    /* Case 2: firmware missing -> serve() returns early, request pending */
    mk_request("dev2", "nope.bin");
    snprintf(p, sizeof p, "%s/dev2", SYSFW);
    serve(p, "nope.bin");
    snprintf(load_p, sizeof load_p, "%s/dev2/loading", SYSFW);
    CHECK(read_int(load_p) == 0, "missing fw leaves request pending");

    /* Case 3: scan() recurses into nested fw dirs (aic8800DC/<file>) and
     * serve() finds the file via the vendor-subdir fallback in find_fw */
    snprintf(p, sizeof p, "%s/aic8800DC", LIBFW);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/aic8800DC/fmacfw.bin", LIBFW);
    write_file(p, "AICFW!");
    snprintf(p, sizeof p, "%s/aic8800DC", SYSFW);
    mkdir(p, 0755);
    mk_request("aic8800DC/fmacfw.bin", "aic8800DC/fmacfw.bin");
    scan(SYSFW, "");
    snprintf(load_p, sizeof load_p, "%s/aic8800DC/fmacfw.bin/loading", SYSFW);
    snprintf(data_p, sizeof data_p, "%s/aic8800DC/fmacfw.bin/data", SYSFW);
    f = fopen(data_p, "rb");
    assert(f);
    memset(buf, 0, sizeof buf);
    n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    CHECK(n == 6 && memcmp(buf, "AICFW!", 6) == 0, "nested firmware served via scan");
    CHECK(read_int(load_p) == 0, "nested request completed");

    printf("%s\n", failed ? "C-TESTS FAILED" : "C-TESTS PASSED");
    return failed ? 1 : 0;
}
