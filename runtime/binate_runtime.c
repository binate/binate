#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// Binate runtime library
// Provides I/O and basic operations for compiled Binate programs.

void bn_print_string(const char *s) {
    fputs(s, stdout);
}

void bn_print_int(int64_t n) {
    printf("%lld", (long long)n);
}

void bn_print_bool(int8_t b) {
    if (b) {
        printf("true");
    } else {
        printf("false");
    }
}

void bn_print_newline(void) {
    printf("\n");
}

void bn_exit(int64_t code) {
    exit((int)code);
}

/* Entry point: calls Binate's main function */
extern void bn_main(void);

int main(void) {
    bn_main();
    return 0;
}
