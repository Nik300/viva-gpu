// Back-end smoke test without Metal: device, buffer, texture, clear pass, readback, fence.
// llvmpipe really renders; Panfrost on the vgpu mock builds and "submits" the job chains (nothing executes, so the
// readback is not checked there).
#include "../vmg.h"
#include <stdio.h>
#include <string.h>

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("FAIL %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char **argv)
{
    const char *which = argc > 1 ? argv[1] : "llvmpipe";
    bool real = !strcmp(which, "llvmpipe");
    char err[256] = "";
    vmg_device *dev = vmg_device_create(which, err, sizeof err);
    CHECK(dev != NULL, "device %s: %s", which, err);
    if (!dev) return 1;
    const vmg_device_info *info = vmg_device_get_info(dev);
    printf("%s: %s, max 2D %u, MSAA %u, subgroup %u\n", which, info->name, info->max_texture_2d, info->max_samples, info->subgroup_size);

    void *contents = NULL;
    vmg_resource *buf = vmg_buffer_create(dev, 4096, NULL, &contents);
    CHECK(buf && contents, "buffer with persistent map");
    if (contents) memset(contents, 0xab, 4096);

    vmg_texture_desc td = { .type = VMG_TEX_2D, .mtl_format = 70 /* RGBA8Unorm */, .width = 64, .height = 32, .depth = 1,
                            .array_length = 1, .mip_levels = 1, .samples = 1, .render_target = true };
    vmg_texture *tex = vmg_texture_create(dev, &td);
    CHECK(tex != NULL, "texture");

    vmg_pass_desc pass = {0};
    pass.color[0].texture = tex;
    pass.color[0].load = VMG_LOAD_CLEAR;
    pass.color[0].store = VMG_STORE_STORE;
    pass.color[0].clear[0] = 1.0; pass.color[0].clear[1] = 0.5; pass.color[0].clear[2] = 0.25; pass.color[0].clear[3] = 1.0;
    vmg_cmd_begin_pass(dev, &pass);
    vmg_cmd_end_pass(dev);
    vmg_cmd_copy_buffer(dev, buf, 0, buf, 2048, 16);
    vmg_fence *fence = NULL;
    vmg_flush(dev, &fence);
    CHECK(vmg_fence_wait(dev, fence, 5000000000ull), "fence signalled");
    vmg_fence_release(dev, fence);

    uint8_t px[64 * 32 * 4] = {0};
    vmg_texture_read(dev, tex, 0, 0, 0, 0, 0, 64, 32, 1, px, 64 * 4, 64 * 32 * 4);
    if (real) {
        CHECK(px[0] == 255 && px[1] == 128 && px[2] == 64 && px[3] == 255, "cleared pixel %u %u %u %u", px[0], px[1], px[2], px[3]);
        CHECK(((uint8_t *)contents)[2048] == 0xab, "buffer copy");
    }

    vmg_texture_release(dev, tex);
    vmg_resource_release(dev, buf);
    vmg_device_destroy(dev);
    printf("%s: %d/%d checks passed\n", which, checks - failures, checks);
    return failures != 0;
}
