// A private, session-specific macOS terminal application for React Native's
// `open -a <REACT_TERMINAL> launchPackager.command` contract. Never runs scripts.
#import <AppKit/AppKit.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static BOOL forward(NSString *configPath, NSString *script) {
    NSData *data = [NSData dataWithContentsOfFile:configPath];
    NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![config isKindOfClass:NSDictionary.class] || ![config[@"socket"] isKindOfClass:NSString.class] || ![config[@"capability"] isKindOfClass:NSString.class]) return NO;
    const char *path = [config[@"socket"] fileSystemRepresentation];
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
    if (strlen(path) >= sizeof(address.sun_path)) return NO;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return NO;
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct timeval limit = {.tv_sec = 3, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
    BOOL ok = NO;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        uid_t uid; gid_t gid;
        if (getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()) {
            NSMutableData *body = [[NSJSONSerialization dataWithJSONObject:@{@"capability":config[@"capability"], @"script":script} options:0 error:nil] mutableCopy];
            [body appendBytes:"\n" length:1];
            size_t offset = 0;
            while (offset < body.length) { ssize_t n = write(fd, (char *)body.bytes + offset, body.length - offset); if (n <= 0) break; offset += n; }
            if (offset == body.length) {
                NSMutableData *reply = [NSMutableData data]; char bytes[2048]; ssize_t n;
                while (reply.length < 4096 && (n = read(fd, bytes, sizeof(bytes))) > 0) { [reply appendBytes:bytes length:n]; if (memchr(bytes, '\n', n)) break; }
                NSDictionary *result = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
                ok = [result isKindOfClass:NSDictionary.class] && [result[@"ok"] isEqual:@YES];
            }
        }
    }
    close(fd); return ok;
}
@interface TerminalLaunchDelegate : NSObject <NSApplicationDelegate>
@property NSUInteger pending;
@property NSUInteger generation;
@end
@implementation TerminalLaunchDelegate
- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {
    // LaunchServices may coalesce documents or deliver another open event to
    // this still-running helper. Do not drop a concurrent project's request.
    self.pending++; self.generation++;
    NSString *config = [NSBundle.mainBundle pathForResource:@"bridge" ofType:@"json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = files.count > 0 && files.count <= 8 && config;
        if (ok) { for (NSString *file in files) { if (!forward(config, file)) ok = NO; } }
        dispatch_async(dispatch_get_main_queue(), ^{
            [app replyToOpenOrPrint:ok ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
            self.pending--; NSUInteger generation = self.generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (self.pending == 0 && self.generation == generation) [app terminate:nil];
            });
        });
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        // Direct mode is also useful to tools that accept an executable rather
        // than a macOS application, and exercises the exact IPC in fixtures.
        if (argc == 4 && strcmp(argv[1], "--request") == 0) return forward(@(argv[2]), @(argv[3])) ? 0 : 1;
        NSApplication *app = NSApplication.sharedApplication;
        TerminalLaunchDelegate *delegate = [TerminalLaunchDelegate new]; app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited]; [app run];
    }
    return 0;
}
