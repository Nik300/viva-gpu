// vmhelper: the privileged half of Viva Manager. Installed setuid root inside the app bundle; the app (user mobile)
// runs it for the few things it cannot do itself. Every command is fixed and checked here: no paths or programs come
// from the caller.
//
//   vmhelper env-write                 stdin -> VivaMTLDriver.bundle/vmg.env (first save keeps vmg.env.orig)
//   vmhelper restart SpringBoard|backboardd
//   vmhelper link CMD..                kern.viva_link as root (commands that change state)
//   vmhelper bootargs-get              next boot's command line: kern.viva_nextbootargs, else the saved file
//   vmhelper bootargs-set              stdin -> kern.viva_nextbootargs (and always the saved file)
//   vmhelper reboot
//   vmhelper procs                     "pid\tname\tcpu_ns\tfootprint\tresident" for every process
//
// Exit status 0 = done; output on stdout, errors on stderr.
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

// libproc (not in the iOS SDK headers; part of libSystem).
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
int reboot(int howto);

#define ENV_PATH      "/System/Library/Extensions/VivaMTLDriver.bundle/vmg.env"
#define BOOTARGS_FILE "/private/var/root/viva-next-bootargs"
#define BOOT_LINE     608   // boot_args CommandLine (mkpayload.py)

static int fail(const char *what) {
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    return 1;
}

static char *read_stdin(size_t max, size_t *len) {
    char *buf = malloc(max + 1);
    size_t n = 0;
    ssize_t r;
    while (buf && n < max && (r = read(0, buf + n, max - n)) > 0) n += (size_t)r;
    if (buf) buf[n] = 0;
    *len = n;
    return buf;
}

// Writes data to path through path.tmp + rename (a crash never leaves half a file).
static int write_atomic(const char *path, const char *data, size_t len, mode_t mode) {
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return fail(tmp);
    if (write(fd, data, len) != (ssize_t)len || fsync(fd) != 0) { close(fd); unlink(tmp); return fail(tmp); }
    close(fd);
    chmod(tmp, mode);
    if (rename(tmp, path) != 0) { unlink(tmp); return fail(path); }
    return 0;
}

static int copy_file(const char *from, const char *to) {
    int in = open(from, O_RDONLY);
    if (in < 0) return -1;
    char buf[65536];
    ssize_t n = read(in, buf, sizeof buf);
    close(in);
    if (n < 0) return -1;
    return write_atomic(to, buf, (size_t)n, 0644);
}

static int env_write(void) {
    size_t len;
    char *data = read_stdin(64 * 1024, &len);
    if (!data) return 1;
    for (size_t i = 0; i < len; i++) {
        if (data[i] == 0) { fprintf(stderr, "env-write: binary data refused\n"); return 1; }
    }
    struct stat st;
    if (stat(ENV_PATH ".orig", &st) != 0) copy_file(ENV_PATH, ENV_PATH ".orig");
    int r = write_atomic(ENV_PATH, data, len, 0644);
    if (r == 0) printf("vmg.env: %zu bytes written\n", len);
    return r;
}

static int kill_named(const char *name) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return fail("proc_listallpids");
    pid_t *pids = calloc((size_t)n + 64, sizeof *pids);
    n = proc_listallpids(pids, (int)(((size_t)n + 64) * sizeof *pids));
    int killed = 0;
    for (int i = 0; i < n; i++) {
        char pn[256] = "";
        if (pids[i] <= 1 || proc_name(pids[i], pn, sizeof pn) <= 0 || strcmp(pn, name) != 0) continue;
        // SIGKILL like killall -9: launchd starts it again at once (SIGTERM lets SpringBoard linger for seconds).
        if (kill(pids[i], SIGKILL) == 0) { printf("%s[%d] stopped\n", name, pids[i]); killed++; }
    }
    free(pids);
    if (!killed) { fprintf(stderr, "%s: not running\n", name); return 1; }
    return 0;
}

static int link_cmd(int argc, char **argv) {
    char cmd[512] = "";
    for (int i = 0; i < argc; i++) {
        if (i) strlcat(cmd, " ", sizeof cmd);
        strlcat(cmd, argv[i], sizeof cmd);
    }
    // The kernel decides what root may do (KA1); nothing that reads or writes memory or storage goes through here.
    static const char *const allowed[] = {"gpu", "disp", "bat", "stat", "wifi status", NULL};
    int ok = 0;
    for (int i = 0; allowed[i]; i++) {
        size_t l = strlen(allowed[i]);
        if (strncmp(cmd, allowed[i], l) == 0 && (cmd[l] == 0 || cmd[l] == ' ')) ok = 1;
    }
    if (!ok) { fprintf(stderr, "link: command not allowed\n"); return 1; }
    static char out[16384];
    size_t len = sizeof out - 1;
    if (sysctlbyname("kern.viva_link", out, &len, cmd, strlen(cmd)) != 0) return fail("kern.viva_link");
    out[len < sizeof out ? len : sizeof out - 1] = 0;
    fputs(out, stdout);
    return 0;
}

static int bootargs_get(void) {
    char buf[BOOT_LINE + 1] = "";
    size_t len = BOOT_LINE;
    if (sysctlbyname("kern.viva_nextbootargs", buf, &len, NULL, 0) == 0) {
        buf[len < BOOT_LINE ? len : BOOT_LINE] = 0;
        printf("kernel\n%s\n", buf);
        return 0;
    }
    int fd = open(BOOTARGS_FILE, O_RDONLY);
    if (fd < 0) { printf("none\n\n"); return 0; }
    ssize_t n = read(fd, buf, BOOT_LINE);
    close(fd);
    buf[n > 0 ? n : 0] = 0;
    buf[strcspn(buf, "\r\n")] = 0;
    printf("file\n%s\n", buf);
    return 0;
}

static int bootargs_set(void) {
    size_t len;
    char *line = read_stdin(BOOT_LINE * 2, &len);
    if (!line) return 1;
    line[strcspn(line, "\r\n")] = 0;
    len = strlen(line);
    if (len == 0 || len >= BOOT_LINE) { fprintf(stderr, "boot-args: length %zu (1..%d)\n", len, BOOT_LINE - 1); return 1; }
    for (size_t i = 0; i < len; i++) {
        if (line[i] < 0x20 || line[i] > 0x7e) { fprintf(stderr, "boot-args: only printable ASCII\n"); return 1; }
    }
    char saved[BOOT_LINE + 2];
    snprintf(saved, sizeof saved, "%s\n", line);
    write_atomic(BOOTARGS_FILE, saved, strlen(saved), 0644);
    if (sysctlbyname("kern.viva_nextbootargs", NULL, NULL, line, len + 1) == 0) {
        printf("kernel\n");
        return 0;
    }
    if (errno == ENOENT) { printf("file\n"); return 0; }   // kernel without KA2: saved for viva-mkboot.sh
    return fail("kern.viva_nextbootargs");
}

static int procs(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return fail("proc_listallpids");
    pid_t *pids = calloc((size_t)n + 64, sizeof *pids);
    n = proc_listallpids(pids, (int)(((size_t)n + 64) * sizeof *pids));
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    for (int i = 0; i < n; i++) {
        struct rusage_info_v0 ri;
        char name[256] = "";
        if (pids[i] == 0) strlcpy(name, "kernel_task", sizeof name);
        else if (proc_name(pids[i], name, sizeof name) <= 0) continue;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V0, (rusage_info_t *)&ri) != 0) continue;
        // Task power info times are in mach_absolute_time units.
        uint64_t cpu = (ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom;
        printf("%d\t%s\t%llu\t%llu\t%llu\n", pids[i], name, (unsigned long long)cpu,
               (unsigned long long)ri.ri_phys_footprint, (unsigned long long)ri.ri_resident_size);
    }
    free(pids);
    return 0;
}

int main(int argc, char **argv) {
    // Only Viva Manager itself (or root, from the USB link) may use it.
    char parent[256] = "";
    if (getuid() != 0 && (proc_name(getppid(), parent, sizeof parent) <= 0 || strcmp(parent, "VivaManager") != 0)) {
        fprintf(stderr, "vmhelper: only for Viva Manager\n");
        return 1;
    }
    if (setuid(0) != 0 || setgid(0) != 0) return fail("setuid (vmhelper must be owned by root with mode 4755)");
    if (argc < 2) { fprintf(stderr, "usage: vmhelper env-write|restart|link|bootargs-get|bootargs-set|reboot|procs\n"); return 2; }
    const char *c = argv[1];
    if (!strcmp(c, "env-write")) return env_write();
    if (!strcmp(c, "restart") && argc == 3 && (!strcmp(argv[2], "SpringBoard") || !strcmp(argv[2], "backboardd")))
        return kill_named(argv[2]);
    if (!strcmp(c, "link") && argc >= 3) return link_cmd(argc - 2, argv + 2);
    if (!strcmp(c, "bootargs-get")) return bootargs_get();
    if (!strcmp(c, "bootargs-set")) return bootargs_set();
    if (!strcmp(c, "procs")) return procs();
    if (!strcmp(c, "reboot")) {
        sync();
        sleep(1);
        sync();
        if (reboot(0) != 0) return fail("reboot");
        return 0;
    }
    fprintf(stderr, "vmhelper: unknown command %s\n", c);
    return 2;
}
