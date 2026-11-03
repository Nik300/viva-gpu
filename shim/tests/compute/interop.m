// Compute C0 probe: OpenCL <-> OpenGL 4.1 core sharing as the shim would use it (CGL share group).
// GL buffer, GL_TEXTURE_2D RGBA8/RGBA16F and an IOSurface GL_TEXTURE_RECTANGLE, written by CL and read back by GL.
// Build: clang -fobjc-arc -framework Foundation -framework OpenGL -framework OpenCL -framework IOSurface -framework QuartzCore tests/compute/interop.m -o build/clinterop
#define GL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenCL/opencl.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
static const char *src =
 "__kernel void fill(__write_only image2d_t img, __global uint *buf, float4 c){ int2 g=(int2)(get_global_id(0),get_global_id(1));"
 " write_imagef(img, g, c); buf[g.y*get_global_size(0)+g.x] = g.x + 1000*g.y; }\n"
 "__kernel void copyimg(__read_only image2d_t s, __write_only image2d_t d){ int2 g=(int2)(get_global_id(0),get_global_id(1));"
 " const sampler_t sm = CLK_NORMALIZED_COORDS_FALSE|CLK_ADDRESS_CLAMP_TO_EDGE|CLK_FILTER_NEAREST; write_imagef(d, g, read_imagef(s, sm, g).zyxw); }\n";
int main(void) { @autoreleasepool {
  CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
  CGLPixelFormatObj pf; GLint n; CGLChoosePixelFormat(a, &pf, &n); CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
  printf("GL %s / %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER));
  cl_context_properties p[] = { CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE, (cl_context_properties)CGLGetShareGroup(ctx), 0 };
  cl_int e; cl_context cl = clCreateContext(p, 0, NULL, NULL, NULL, &e); printf("clCreateContext(sharegroup) %d\n", e);
  cl_device_id dev; size_t sz; clGetContextInfo(cl, CL_CONTEXT_DEVICES, sizeof dev, &dev, &sz); char name[128]; clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, 0); printf("CL devices in context: %zu first=%s\n", sz/sizeof dev, name);
  // pick the GPU in the share group
  cl_device_id gpu = 0; size_t nd = sz/sizeof(cl_device_id); cl_device_id ds[4]; clGetContextInfo(cl, CL_CONTEXT_DEVICES, sizeof ds, ds, NULL);
  for (size_t i=0;i<nd;i++){ cl_device_type t; clGetDeviceInfo(ds[i], CL_DEVICE_TYPE, sizeof t, &t, 0); if (t & CL_DEVICE_TYPE_GPU) gpu = ds[i]; }
  cl_command_queue q = clCreateCommandQueue(cl, gpu, 0, &e);
  cl_program pr = clCreateProgramWithSource(cl, 1, &src, NULL, &e); e = clBuildProgram(pr, 1, &gpu, "", NULL, NULL); printf("build %d\n", e);
  // GL 2D texture + GL buffer
  GLuint tex, buf; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glGenBuffers(1, &buf); glBindBuffer(GL_ARRAY_BUFFER, buf); glBufferData(GL_ARRAY_BUFFER, 64*64*4, NULL, GL_DYNAMIC_DRAW); glFinish();
  cl_mem ct = clCreateFromGLTexture(cl, CL_MEM_READ_WRITE, GL_TEXTURE_2D, 0, tex, &e); printf("clCreateFromGLTexture(2D RGBA8) %d\n", e);
  cl_mem cb = clCreateFromGLBuffer(cl, CL_MEM_READ_WRITE, buf, &e); printf("clCreateFromGLBuffer %d\n", e);
  cl_kernel k = clCreateKernel(pr, "fill", &e); cl_float4 c = {{0.25f, 0.5f, 1.0f, 1.0f}};
  clSetKernelArg(k, 0, sizeof ct, &ct); clSetKernelArg(k, 1, sizeof cb, &cb); clSetKernelArg(k, 2, sizeof c, &c);
  cl_mem objs[] = { ct, cb }; size_t g[2] = {64, 64};
  for (int it = 0; it < 4; it++) {
    double t0 = CACurrentMediaTime(); glFlush();
    clEnqueueAcquireGLObjects(q, 2, objs, 0, NULL, NULL); e = clEnqueueNDRangeKernel(q, k, 2, NULL, g, NULL, 0, NULL, NULL);
    clEnqueueReleaseGLObjects(q, 2, objs, 0, NULL, NULL); clFlush(q); clFinish(q);
    printf("dispatch %d: %d, acquire+run+release+finish %.2f ms\n", it, e, (CACurrentMediaTime()-t0)*1000);
  }
  uint8_t px[64*64*4]; glBindTexture(GL_TEXTURE_2D, tex); glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, px); printf("GL reads texture px(5,7)=%d,%d,%d,%d\n", px[(7*64+5)*4], px[(7*64+5)*4+1], px[(7*64+5)*4+2], px[(7*64+5)*4+3]);
  uint32_t *bp = malloc(64*64*4); glGetBufferSubData(GL_ARRAY_BUFFER, 0, 64*64*4, bp); printf("GL reads buffer [7*64+5]=%u\n", bp[7*64+5]);
  // IOSurface-backed rectangle texture (what CAMetalLayer drawables use)
  IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@64,(id)kIOSurfaceHeight:@64,(id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
  GLuint rt; glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_RECTANGLE, rt);
  CGLError ce = CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE, GL_RGBA, 64, 64, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surf, 0); glFinish();
  cl_mem cr = clCreateFromGLTexture(cl, CL_MEM_WRITE_ONLY, GL_TEXTURE_RECTANGLE, 0, rt, &e); printf("CGLTexImageIOSurface2D %d, clCreateFromGLTexture(RECT IOSurface) %d\n", ce, e);
  if (cr) { cl_kernel k2 = clCreateKernel(pr, "copyimg", &e); clSetKernelArg(k2, 0, sizeof ct, &ct); clSetKernelArg(k2, 1, sizeof cr, &cr); cl_mem o2[] = {ct, cr};
    clEnqueueAcquireGLObjects(q, 2, o2, 0, NULL, NULL); e = clEnqueueNDRangeKernel(q, k2, 2, NULL, g, NULL, 0, NULL, NULL); clEnqueueReleaseGLObjects(q, 2, o2, 0, NULL, NULL); clFinish(q);
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL); uint8_t *sp = IOSurfaceGetBaseAddress(surf); printf("copy to IOSurface: %d, surface BGRA px(5,7)=%d,%d,%d,%d\n", e, sp[(7*64+5)*4], sp[(7*64+5)*4+1], sp[(7*64+5)*4+2], sp[(7*64+5)*4+3]); IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL); }
  // RGBA16F (CoreImage working format)
  GLuint hf; glGenTextures(1, &hf); glBindTexture(GL_TEXTURE_2D, hf); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, 64, 64, 0, GL_RGBA, GL_HALF_FLOAT, NULL); glFinish();
  cl_mem ch = clCreateFromGLTexture(cl, CL_MEM_WRITE_ONLY, GL_TEXTURE_2D, 0, hf, &e); printf("clCreateFromGLTexture(2D RGBA16F) %d\n", e);
}}
