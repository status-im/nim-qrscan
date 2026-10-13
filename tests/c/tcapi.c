/* C ABI test: results, options, invalid arguments, UTF-8, two threads. */
#include "qrscan.h"
#include "qrgen_c.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int contains(const char* s, const char* sub) { return s && strstr(s, sub) != NULL; }

static void* worker(void* arg)
{
    const char* text = (const char*)arg;
    int w, h;
    uint8_t* img = qr_luma(text, 4, 4, &w, &h);
    for (int i = 0; i < 50; ++i) {
        char* r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, NULL);
        assert(contains(r, "\"ok\":true") && contains(r, text));
        qrscan_free(r);
    }
    free(img);
    return NULL;
}

int main(void)
{
    qrscan_init();
    assert(strlen(qrscan_version()) > 0);

    int w, h;
    uint8_t* img = qr_luma("capi-hello", 4, 4, &w, &h);
    char* r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, NULL);
    assert(contains(r, "\"ok\":true"));
    assert(contains(r, "\"text\":\"capi-hello\""));
    assert(contains(r, "\"format\":\"QRCode\""));
    assert(contains(r, "\"bytes\":\"636170692d68656c6c6f\"")); /* hex of capi-hello */
    assert(contains(r, "\"corners\":[["));
    qrscan_free(r);

    /* UTF-8 payload (Review Focus 5) */
    int uw, uh;
    uint8_t* u = qr_luma("\xC5\xBD" "aba \xF0\x9F\x90\xB8", 4, 4, &uw, &uh);
    r = qrscan_decode_luma(u, (size_t)uw * uh, uw, uh, uw, NULL);
    assert(contains(r, "\xC5\xBD" "aba \xF0\x9F\x90\xB8"));
    qrscan_free(r);
    free(u);

    /* options */
    r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, "{\"formats\":[\"DataMatrix\"]}");
    assert(contains(r, "\"ok\":true") && contains(r, "\"codes\":[]"));
    qrscan_free(r);
    r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, "{\"formats\":[\"NoSuchFormat\"]}");
    assert(contains(r, "\"ok\":false") && contains(r, "\"invalidOptions\""));
    qrscan_free(r);
    r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, "{not json");
    assert(contains(r, "\"invalidOptions\""));
    qrscan_free(r);
    r = qrscan_decode_luma(img, (size_t)w * h, w, h, w, "{\"tryHarder\":\"yes\"}");
    assert(contains(r, "\"invalidOptions\""));
    qrscan_free(r);

    /* invalid arguments (Review Focus 4) */
    r = qrscan_decode_luma(NULL, 0, 10, 10, 10, NULL);
    assert(contains(r, "\"invalidInput\"")); qrscan_free(r);
    r = qrscan_decode_luma(img, 10, w, h, w, NULL);
    assert(contains(r, "\"invalidInput\"")); qrscan_free(r);
    r = qrscan_decode_luma(img, (size_t)w * h, w, h, w - 1, NULL);
    assert(contains(r, "\"invalidInput\"")); qrscan_free(r);
    r = qrscan_decode_luma(img, (size_t)w * h, -1, h, w, NULL);
    assert(contains(r, "\"invalidInput\"")); qrscan_free(r);
    qrscan_free(NULL);
    free(img);

    /* two threads at once */
    pthread_t a, b;
    pthread_create(&a, NULL, worker, "thread-a");
    pthread_create(&b, NULL, worker, "thread-b");
    pthread_join(a, NULL);
    pthread_join(b, NULL);

    puts("tcapi: OK");
    return 0;
}
