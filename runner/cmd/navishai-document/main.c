#include <LibreOfficeKit/LibreOfficeKit.h>
#include <LibreOfficeKit/LibreOfficeKitInit.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { LOK_DOCTYPE_TEXT = 0 };

int main(int argc, char **argv) {
    (void)argv;
    char cwd[PATH_MAX], profile[PATH_MAX + 32], input[PATH_MAX + 16], output[PATH_MAX + 16];
    if (argc != 1 || !getcwd(cwd, sizeof(cwd))) return 1;
    if (snprintf(profile, sizeof(profile), "vnd.sun.star.pathname:%s/profile", cwd) >= (int)sizeof(profile)) return 1;
    if (snprintf(input, sizeof(input), "%s/input.doc", cwd) >= (int)sizeof(input) || snprintf(output, sizeof(output), "%s/input.txt", cwd) >= (int)sizeof(output)) return 1;
    LibreOfficeKit *office = lok_init_2("/usr/lib/libreoffice/program", profile);
    if (!office) return 1;
    LibreOfficeKitDocument *document = office->pClass->documentLoad(office, input);
    if (!document) _exit(1);
    if (document->pClass->getDocumentType(document) != LOK_DOCTYPE_TEXT) _exit(1);
    int success = document->pClass->saveAs(document, output, "txt", "UTF8");
    _exit(success ? 0 : 1);
}
