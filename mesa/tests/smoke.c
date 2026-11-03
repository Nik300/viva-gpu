/*
 * Smoke test for libmesa_viva.a
 *  (a) llvmpipe + null sw winsys: clear a 64x64 RGBA8 render target, read back
 *  (b) nir_builder fragment shader -> panfrost Valhall compiler (Mali-G57, v9)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/box.h"
#include "util/u_inlines.h"
#include "util/u_dynarray.h"
#include "llvmpipe/lp_public.h"
#include "sw/null/null_sw_winsys.h"
#include "frontend/sw_winsys.h"

#include "compiler/glsl_types.h"
#include "nir.h"
#include "nir_builder.h"
#include "panfrost/compiler/pan_compiler.h"
#include "panfrost/model/pan_model.h"

static int
test_llvmpipe(void)
{
   struct sw_winsys *ws = null_sw_create();
   struct pipe_screen *screen = ws ? llvmpipe_create_screen(ws) : NULL;
   if (!screen) {
      fprintf(stderr, "llvmpipe: screen creation failed\n");
      return 1;
   }
   printf("llvmpipe: screen '%s' (%s)\n", screen->get_name(screen),
          screen->get_vendor(screen));
   struct pipe_context *pipe = screen->context_create(screen, NULL, 0);
   if (!pipe) {
      fprintf(stderr, "llvmpipe: context creation failed\n");
      return 1;
   }

   struct pipe_resource templ = {0};
   templ.target = PIPE_TEXTURE_2D;
   templ.format = PIPE_FORMAT_R8G8B8A8_UNORM;
   templ.width0 = 64;
   templ.height0 = 64;
   templ.depth0 = 1;
   templ.array_size = 1;
   templ.last_level = 0;
   templ.bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW;
   templ.usage = PIPE_USAGE_DEFAULT;
   struct pipe_resource *tex = screen->resource_create(screen, &templ);
   if (!tex) {
      fprintf(stderr, "llvmpipe: resource_create failed\n");
      return 1;
   }

   struct pipe_framebuffer_state fb = {0};
   fb.width = 64;
   fb.height = 64;
   fb.layers = 1;
   fb.nr_cbufs = 1;
   fb.cbufs[0].texture = tex;
   fb.cbufs[0].format = tex->format;
   fb.cbufs[0].level = 0;
   fb.cbufs[0].first_layer = 0;
   fb.cbufs[0].last_layer = 0;
   pipe->set_framebuffer_state(pipe, &fb);

   union pipe_color_union color = {.f = {0.25f, 0.5f, 0.75f, 1.0f}};
   pipe->clear(pipe, PIPE_CLEAR_COLOR0, ~0u, 0, NULL, &color, 0.0, 0);

   struct pipe_fence_handle *fence = NULL;
   pipe->flush(pipe, &fence, 0);
   if (fence) {
      screen->fence_finish(screen, NULL, fence, OS_TIMEOUT_INFINITE);
      screen->fence_reference(screen, &fence, NULL);
   }

   struct pipe_box box;
   u_box_2d(0, 0, 64, 64, &box);
   struct pipe_transfer *xfer = NULL;
   const uint8_t *map = pipe->texture_map(pipe, tex, 0, PIPE_MAP_READ, &box, &xfer);
   if (!map) {
      fprintf(stderr, "llvmpipe: texture_map failed\n");
      return 1;
   }
   const uint8_t expect[4] = {64, 128, 191, 255};
   int bad = 0;
   for (unsigned y = 0; y < 64 && !bad; y++) {
      const uint8_t *row = map + y * xfer->stride;
      for (unsigned x = 0; x < 64; x++) {
         const uint8_t *p = row + x * 4;
         for (int c = 0; c < 4; c++) {
            if (abs((int)p[c] - (int)expect[c]) > 1) {
               fprintf(stderr, "llvmpipe: pixel (%u,%u) = %u,%u,%u,%u expected %u,%u,%u,%u\n",
                       x, y, p[0], p[1], p[2], p[3],
                       expect[0], expect[1], expect[2], expect[3]);
               bad = 1;
               break;
            }
         }
         if (bad)
            break;
      }
   }
   printf("llvmpipe: pixel(0,0)=%u,%u,%u,%u pixel(63,63)=%u,%u,%u,%u -> %s\n",
          map[0], map[1], map[2], map[3],
          map[63 * xfer->stride + 63 * 4 + 0], map[63 * xfer->stride + 63 * 4 + 1],
          map[63 * xfer->stride + 63 * 4 + 2], map[63 * xfer->stride + 63 * 4 + 3],
          bad ? "FAIL" : "OK");
   pipe->texture_unmap(pipe, xfer);

   memset(&fb, 0, sizeof(fb));
   pipe->set_framebuffer_state(pipe, &fb);
   pipe_resource_reference(&tex, NULL);
   pipe->destroy(pipe);
   screen->destroy(screen);
   return bad;
}

static unsigned
type_size_vec4(const struct glsl_type *type, bool bindless)
{
   (void)bindless;
   return glsl_count_attribute_slots(type, false);
}

/* Mali-G57 (TNAx): GPU_ID register 0x9093xxxx -> arch 9 (Valhall v9). */
#define G57_GPU_ID 0x90930000ull

static int
test_panfrost_compiler(void)
{
   glsl_type_singleton_init_or_ref();

   const uint64_t gpu_id = G57_GPU_ID;
   const unsigned arch = pan_arch(gpu_id);
   const nir_shader_compiler_options *opts =
      pan_get_nir_shader_compiler_options(arch, MESA_SHADER_FRAGMENT, false);

   nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_FRAGMENT, opts,
                                                  "smoke_fs");
   nir_variable *out = nir_create_variable_with_location(
      b.shader, nir_var_shader_out, FRAG_RESULT_DATA0, glsl_vec4_type());
   out->data.driver_location = 0;
   nir_store_var(&b, out, nir_imm_vec4(&b, 1.0f, 0.5f, 0.25f, 1.0f), 0xf);
   nir_shader *nir = b.shader;
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));

   /* Same order as the gallium driver (pan_shader.c). */
   pan_preprocess_nir(nir, gpu_id);
   NIR_PASS(_, nir, nir_lower_io, nir_var_shader_in | nir_var_shader_out,
            type_size_vec4, nir_lower_io_use_interpolated_input_intrinsics);
   NIR_PASS(_, nir, nir_opt_constant_folding);

   struct pan_compile_inputs inputs = {
      .gpu_id = gpu_id,
      .gpu_variant = 0,
   };
   struct pan_shader_info info;
   pan_postprocess_nir(nir, &inputs, &info);

   struct util_dynarray binary = UTIL_DYNARRAY_INIT;
   pan_shader_compile(nir, &inputs, &binary, &info);

   const char *model = "?";
   const struct pan_model *m = pan_get_model(gpu_id, 0);
   if (m)
      model = m->name;

   printf("panfrost: gpu_id=0x%llx (%s, arch v%u) fragment shader binary: %u bytes\n",
          (unsigned long long)gpu_id, model, arch, (unsigned)binary.size);
   pan_stats_fprintf(stdout, "panfrost: ", &info.stats);
   if (binary.size) {
      printf("panfrost: disassembly:\n");
      pan_disassemble(stdout, binary.data, binary.size, gpu_id, false);
   }

   int ok = binary.size > 0 && info.stats.isa == PAN_STAT_VALHALL;
   printf("panfrost: -> %s\n", ok ? "OK" : "FAIL");

   util_dynarray_fini(&binary);
   ralloc_free(nir);
   glsl_type_singleton_decref();
   return !ok;
}

int
main(void)
{
   int fail = 0;
   fail |= test_llvmpipe();
   fail |= test_panfrost_compiler();
   printf("smoke: %s\n", fail ? "FAILED" : "PASSED");
   return fail;
}
