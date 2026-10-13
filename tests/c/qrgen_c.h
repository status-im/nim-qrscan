/* Test helper: renders text as a QR code into a malloc'ed 8-bit grayscale
   buffer (black 0, white 255) using Nayuki's qrcodegen. */
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "qrcodegen.h"

static uint8_t* qr_luma(const char* text, int scale, int quiet, int* outW, int* outH)
{
    uint8_t qr[qrcodegen_BUFFER_LEN_MAX], tmp[qrcodegen_BUFFER_LEN_MAX];
    if (!qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN,
                              qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true))
        return NULL;
    int size = qrcodegen_getSize(qr);
    int side = (size + 2 * quiet) * scale;
    uint8_t* img = (uint8_t*)malloc((size_t)side * side);
    memset(img, 255, (size_t)side * side);
    for (int my = 0; my < size; ++my)
        for (int mx = 0; mx < size; ++mx)
            if (qrcodegen_getModule(qr, mx, my))
                for (int dy = 0; dy < scale; ++dy)
                    memset(img + ((my + quiet) * scale + dy) * side + (mx + quiet) * scale, 0, scale);
    *outW = side;
    *outH = side;
    return img;
}
