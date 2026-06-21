/*
 * TeXSlide native launcher.
 *
 * macOS on Apple Silicon refuses to treat a shell script as a native main
 * executable and demands Rosetta. The .app's CFBundleExecutable must therefore
 * be a real Mach-O binary. This tiny program is that binary: it locates run.sh
 * next to itself (inside Contents/MacOS) and execs it via /bin/bash, forwarding
 * any arguments (e.g. a PDF path passed when opening a document).
 */
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <libgen.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    char exepath[PATH_MAX];
    uint32_t size = sizeof(exepath);
    if (_NSGetExecutablePath(exepath, &size) != 0) {
        fprintf(stderr, "TeXSlide: cannot resolve executable path\n");
        return 1;
    }

    /* directory containing this executable: .../Contents/MacOS */
    char dirbuf[PATH_MAX];
    strncpy(dirbuf, exepath, sizeof(dirbuf));
    dirbuf[sizeof(dirbuf) - 1] = '\0';
    char *dir = dirname(dirbuf);

    char script[PATH_MAX];
    snprintf(script, sizeof(script), "%s/run.sh", dir);

    /* Build: /bin/bash run.sh [original args...] */
    char **newargv = malloc(sizeof(char *) * (argc + 2));
    if (!newargv) {
        fprintf(stderr, "TeXSlide: out of memory\n");
        return 1;
    }
    newargv[0] = "/bin/bash";
    newargv[1] = script;
    for (int i = 1; i < argc; i++) {
        newargv[i + 1] = argv[i];
    }
    newargv[argc + 1] = NULL;

    execv("/bin/bash", newargv);
    perror("TeXSlide: execv /bin/bash failed");
    return 1;
}
