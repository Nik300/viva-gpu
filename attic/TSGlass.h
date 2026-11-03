// TeraScale Glass (docs/PIANO-GLASS.md): Apple's Liquid Glass shader inside Moraea's OpenGL compositor.
#pragma once
#import <Foundation/Foundation.h>

// Apple's glass shaders as GLSL 4.10 from the AIR translator, keyed by function name (glass_background_sdf_no_bleed_lpf,
// glass_background_no_bleed_lpf, glass_background_sdf_lpf, glass_background_lpf, variable_blur_downsample_frag_lpf),
// turned into one GLSL 1.20 (+ EXT_gpu_shader4) snippet that defines tsg_glass[_tex][_bleed]() and reads their
// parameters from Moraea's cg9m_g[26]. nil (and *error) when the shaders use something the mapping does not cover.
NSString *TSGlassBuildSnippet(NSDictionary<NSString *, NSString *> *glsl410, NSString **error);

// Moraea's glass fragment shader with the snippet inserted and its cg9m_gbs(bleed) / cg9m_gbt(..., bleed) call routed
// to the matching tsg_glass*(). nil when the source is not the shape the snippet expects (another Moraea version).
NSString *TSGlassCompose(NSString *moraeaFragment, NSString *snippet);

// Wraps the link/use entries of a CGL context's dispatch table (idempotent). The WindowServer path finds the
// contexts by itself; the lab calls this from a CGLCreateContext interposer (tests/glass/lab.c).
void TSGlassHookContext(void *cglContext);

// Starts the component in this process if policy, kill switch and crash guard allow it (WindowServer only, or a
// lab copy named WindowServer). Called by a constructor; exported for the lab.
void TSGlassStart(void);

// System.Glass on in policy.plist (trial not expired) and no kill switch.
BOOL TSGlassWanted(void);
