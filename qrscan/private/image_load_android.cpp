// Android fallback for formats Qt has no plugin for (HEIC/HEIF): the
// platform's BitmapFactory decodes them from API 28. Grayscale out.
// Compiled only on Android (image_load.nim).

#include <QtCore/QJniEnvironment>
#include <QtCore/QJniObject>

#include <cstdint>
#include <cstdlib>
#include <cstring>

extern "C" void qrscan_android_free(uint8_t* data)
{
    std::free(data);
}

// Returns 1 and a malloc'ed width*height luma buffer, or 0 if Android can't
// decode the file either. The longest side is sub-sampled to <= max_dim.
extern "C" int qrscan_android_decode_gray(const char* path, int max_dim,
                                          int* width, int* height, uint8_t** data)
{
    *width = 0;
    *height = 0;
    *data = nullptr;
    QJniEnvironment env;
    const QJniObject jpath = QJniObject::fromString(QString::fromUtf8(path));

    // Bounds first, to pick the sample size.
    QJniObject opts("android/graphics/BitmapFactory$Options");
    if (!opts.isValid())
        return 0;
    opts.setField<jboolean>("inJustDecodeBounds", true);
    QJniObject::callStaticObjectMethod(
        "android/graphics/BitmapFactory", "decodeFile",
        "(Ljava/lang/String;Landroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;",
        jpath.object<jstring>(), opts.object());
    env.checkAndClearExceptions();
    const int ow = opts.getField<jint>("outWidth");
    const int oh = opts.getField<jint>("outHeight");
    if (ow <= 0 || oh <= 0)
        return 0;
    int sample = 1;
    while ((ow > oh ? ow : oh) / sample > max_dim)
        sample *= 2;

    opts.setField<jboolean>("inJustDecodeBounds", false);
    opts.setField<jint>("inSampleSize", sample);
    QJniObject bitmap = QJniObject::callStaticObjectMethod(
        "android/graphics/BitmapFactory", "decodeFile",
        "(Ljava/lang/String;Landroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;",
        jpath.object<jstring>(), opts.object());
    if (!bitmap.isValid())
        return 0;
    const int w = bitmap.callMethod<jint>("getWidth");
    const int h = bitmap.callMethod<jint>("getHeight");
    if (w <= 0 || h <= 0)
        return 0;

    jintArray pixels = env->NewIntArray(w * h);
    if (!pixels) { // OutOfMemoryError pending
        env.checkAndClearExceptions();
        bitmap.callMethod<void>("recycle");
        return 0;
    }
    // getPixels returns ARGB_8888 ints whatever the bitmap's config.
    bitmap.callMethod<void>("getPixels", "([IIIIIII)V", pixels, 0, w, 0, 0, w, h);
    bitmap.callMethod<void>("recycle");
    if (env.checkAndClearExceptions()) {
        env->DeleteLocalRef(pixels);
        return 0;
    }

    auto* out = static_cast<uint8_t*>(std::malloc(size_t(w) * size_t(h)));
    if (!out) {
        env->DeleteLocalRef(pixels);
        return 0;
    }
    jint* argb = env->GetIntArrayElements(pixels, nullptr);
    if (!argb) {
        env.checkAndClearExceptions();
        std::free(out);
        env->DeleteLocalRef(pixels);
        return 0;
    }
    // Composited onto white, as on the Qt path: transparency reads as paper.
    for (int i = 0; i < w * h; ++i) {
        const uint32_t p = uint32_t(argb[i]);
        const uint32_t a = p >> 24;
        const uint32_t r = (p >> 16) & 0xFF, g = (p >> 8) & 0xFF, b = p & 0xFF;
        const uint32_t luma = (299 * r + 587 * g + 114 * b) / 1000;
        out[i] = uint8_t((luma * a + 255 * (255 - a)) / 255);
    }
    env->ReleaseIntArrayElements(pixels, argb, JNI_ABORT);
    env->DeleteLocalRef(pixels);

    *width = w;
    *height = h;
    *data = out;
    return 1;
}
