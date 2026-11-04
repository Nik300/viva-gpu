#import "VMApp.h"
#include <errno.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern char **environ;

@implementation VMSystem

+ (int)runHelper:(NSArray<NSString *> *)args input:(NSString *)input output:(NSString **)output {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"vmhelper"];
    int in[2], out[2];
    if (pipe(in) != 0) return -1;
    if (pipe(out) != 0) { close(in[0]); close(in[1]); return -1; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, in[0], 0);
    posix_spawn_file_actions_adddup2(&fa, out[1], 1);
    posix_spawn_file_actions_adddup2(&fa, out[1], 2);
    posix_spawn_file_actions_addclose(&fa, in[1]);
    posix_spawn_file_actions_addclose(&fa, out[0]);
    char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = (char *)args[i].UTF8String;
    pid_t pid;
    int r = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(in[0]);
    close(out[1]);
    if (r != 0) {
        close(in[1]);
        close(out[0]);
        if (output) *output = [NSString stringWithFormat:@"vmhelper non avviato: %s", strerror(r)];
        return -1;
    }
    NSData *inData = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (inData.length) write(in[1], inData.bytes, inData.length);
    close(in[1]);
    NSMutableData *data = [NSMutableData data];
    char buf[16384];
    ssize_t n;
    while ((n = read(out[0], buf, sizeof buf)) > 0) [data appendBytes:buf length:(NSUInteger)n];
    close(out[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

+ (NSString *)sysctlString:(const char *)name {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0) return nil;
    char *buf = calloc(len + 1, 1);
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0) { free(buf); return nil; }
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

+ (BOOL)sysctlExists:(const char *)name {
    int mib[CTL_MAXNAME];
    size_t n = CTL_MAXNAME;
    return sysctlnametomib(name, mib, &n) == 0;
}

+ (int64_t)sysctlInt:(const char *)name {
    int64_t v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
    if (len == sizeof(int32_t)) return (int64_t)*(int32_t *)&v;
    return v;
}

+ (NSString *)link:(NSString *)command error:(int *)err {
    static char out[16384];
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    size_t len = sizeof out - 1;
    const char *cmd = command.UTF8String;
    int r = sysctlbyname("kern.viva_link", out, &len, (void *)cmd, strlen(cmd));
    NSString *s = nil;
    if (r == 0) {
        out[MIN(len, sizeof out - 1)] = 0;
        s = [NSString stringWithUTF8String:out];
    } else if (err) {
        *err = errno;
    }
    [lock unlock];
    return s;
}

+ (NSArray *)loadJSON:(NSString *)name {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:NSArray.class] ? obj : @[];
}

@end

void VMRunHelper(NSArray<NSString *> *args, NSString *input, void (^completion)(int status, NSString *output)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        int status = [VMSystem runHelper:args input:input output:&out];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status, out ?: @""); });
    });
}
