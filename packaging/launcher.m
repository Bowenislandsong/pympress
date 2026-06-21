/*
 * TeXSlide native macOS launcher.
 *
 * The GTK/Python app understands PDF paths passed on argv, but Finder/open(1)
 * sends document-open Apple Events to the app bundle instead of appending paths
 * to argv. This tiny Cocoa executable collects those initial document-open
 * events, then execs Contents/MacOS/run.sh and forwards the files as arguments.
 */
#import <Cocoa/Cocoa.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface TeXSlideLauncherDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) BOOL launched;
@property(nonatomic, strong) NSMutableArray<NSString *> *files;
@end

@implementation TeXSlideLauncherDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _files = [NSMutableArray array];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [self launch];
                   });
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (filename != nil && ![self.files containsObject:filename]) {
        [self.files addObject:filename];
    }
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    for (NSString *filename in filenames) {
        if (filename != nil && ![self.files containsObject:filename]) {
            [self.files addObject:filename];
        }
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if ([url isFileURL]) {
            NSString *filename = [url path];
            if (filename != nil && ![self.files containsObject:filename]) {
                [self.files addObject:filename];
            }
        }
    }
}

- (void)launch {
    if (self.launched) {
        return;
    }
    self.launched = YES;

    char exepath[PATH_MAX];
    uint32_t size = sizeof(exepath);
    if (_NSGetExecutablePath(exepath, &size) != 0) {
        fprintf(stderr, "TeXSlide: cannot resolve executable path\n");
        exit(1);
    }

    char dirbuf[PATH_MAX];
    strncpy(dirbuf, exepath, sizeof(dirbuf));
    dirbuf[sizeof(dirbuf) - 1] = '\0';
    char *dir = dirname(dirbuf);

    char script[PATH_MAX];
    snprintf(script, sizeof(script), "%s/run.sh", dir);

    NSArray<NSString *> *argv = [[NSProcessInfo processInfo] arguments];
    NSUInteger originalArgs = [argv count] > 0 ? [argv count] - 1 : 0;
    NSUInteger fileArgs = [self.files count];
    char **newargv = calloc(originalArgs + fileArgs + 3, sizeof(char *));
    if (newargv == NULL) {
        fprintf(stderr, "TeXSlide: out of memory\n");
        exit(1);
    }

    NSUInteger n = 0;
    newargv[n++] = "/bin/bash";
    newargv[n++] = script;

    for (NSUInteger i = 1; i < [argv count]; i++) {
        newargv[n++] = (char *)[[argv objectAtIndex:i] fileSystemRepresentation];
    }
    for (NSString *filename in self.files) {
        newargv[n++] = (char *)[filename fileSystemRepresentation];
    }
    newargv[n] = NULL;

    execv("/bin/bash", newargv);
    perror("TeXSlide: execv /bin/bash failed");
    exit(1);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        TeXSlideLauncherDelegate *delegate = [[TeXSlideLauncherDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
