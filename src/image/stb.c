// stb_image and stb_image_write, from memory only and on the caller's allocator. See root.zig.

#include <stddef.h>
#include <string.h>

// Zig's side, passed into each call so this file needs nothing linked from it.
struct tuft_image_hooks {
    void *context;
    void *(*alloc)(void *context, size_t size);
    void *(*realloc)(void *context, void *ptr, size_t size);
    void (*free)(void *context, void *ptr);
    void (*assert_failed)(const char *expr);
};

static _Thread_local const struct tuft_image_hooks *hooks;

#define TUFT_IMAGE_ASSERT(x) ((x) ? (void)0 : hooks->assert_failed(#x))

#define STBI_ASSERT(x) TUFT_IMAGE_ASSERT(x)
#define STBI_MALLOC(size) hooks->alloc(hooks->context, size)
#define STBI_REALLOC(ptr, size) hooks->realloc(hooks->context, ptr, size)
#define STBI_FREE(ptr) hooks->free(hooks->context, ptr)
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_ONLY_GIF
// Static so nothing clashes with another copy of stb in the same process
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STBIW_ASSERT(x) TUFT_IMAGE_ASSERT(x)
#define STBIW_MALLOC(size) hooks->alloc(hooks->context, size)
#define STBIW_REALLOC(ptr, size) hooks->realloc(hooks->context, ptr, size)
#define STBIW_FREE(ptr) hooks->free(hooks->context, ptr)
#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

static const struct tuft_image_hooks *use(const struct tuft_image_hooks *h) {
    const struct tuft_image_hooks *saved = hooks;
    hooks = h;
    return saved;
}

int tuft_image_info(const struct tuft_image_hooks *h, const unsigned char *bytes, int len, int *width, int *height) {
    const struct tuft_image_hooks *saved = use(h);
    int channels = 0;
    int ok = stbi_info_from_memory(bytes, len, width, height, &channels);
    hooks = saved;
    return ok;
}

// Always RGBA. Free it with tuft_image_release. Null says why in `failure`.
unsigned char *tuft_image_decode(const struct tuft_image_hooks *h, const unsigned char *bytes, int len, int *width, int *height, const char **failure) {
    const struct tuft_image_hooks *saved = use(h);
    int channels = 0;
    unsigned char *pixels = stbi_load_from_memory(bytes, len, width, height, &channels, 4);
    if (!pixels) *failure = stbi_failure_reason();
    hooks = saved;
    return pixels;
}

void tuft_image_release(const struct tuft_image_hooks *h, void *pixels) {
    const struct tuft_image_hooks *saved = use(h);
    stbi_image_free(pixels);
    hooks = saved;
}

// RGBA rows `stride` apart. Calls `write` once with the whole file.
int tuft_image_png(const struct tuft_image_hooks *h, stbi_write_func *write, void *context, int width, int height, const void *rgba, int stride) {
    const struct tuft_image_hooks *saved = use(h);
    int ok = stbi_write_png_to_func(write, context, width, height, 4, rgba, stride);
    hooks = saved;
    return ok;
}
