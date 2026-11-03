// Compute C0.1: what each CL call costs the issuing thread on this driver, to decide how the runtime brackets
// GL objects. Questions: does clEnqueueReleaseGLObjects wait for the kernel (heavy vs empty kernel)? does it
// scale with the number of objects? what is the floor of a CL submission without any GL object? does an
// out-of-order or second queue help? GPU-side times come from CL profiling events.
// Build: make build/clcost   Run: build/clcost
#define GL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenCL/opencl.h>
#import <mach/mach_time.h>

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static const char *kSrc =
    "__kernel void spin(__global float *p, int n) { float v = p[get_global_id(0)];"
    "  for (int i = 0; i < n; i++) v = v * 1.0000001f + 0.5f; p[get_global_id(0)] = v; }\n"
    "__kernel void touch(__write_only image2d_t img) { write_imagef(img, (int2)(get_global_id(0), 0), (float4)(1)); }\n";

static cl_context gCL;
static cl_device_id gDev;
static cl_kernel gSpin, gTouch;
static cl_mem gBuf;

static double gpuMs(cl_event e) {
    cl_ulong s = 0, en = 0;
    clGetEventProfilingInfo(e, CL_PROFILING_COMMAND_START, sizeof s, &s, NULL);
    clGetEventProfilingInfo(e, CL_PROFILING_COMMAND_END, sizeof en, &en, NULL);
    return (en - s) / 1e6;
}

// One bracket on `nobj` GL textures around a spin kernel of `iters` iterations; CPU time per call.
static void bracket(cl_command_queue q, cl_mem *objs, int nobj, int iters, int reps, const char *label) {
    size_t g = 64 * 1024;
    clSetKernelArg(gSpin, 1, sizeof iters, &iters);
    double t[5] = {0}, gpu = 0;
    for (int r = 0; r < reps + 3; r++) {
        cl_event ev;
        double a = now_ms(); glFlush();
        double b = now_ms(); if (nobj) clEnqueueAcquireGLObjects(q, nobj, objs, 0, NULL, NULL);
        double c = now_ms(); clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, &ev);
        double d = now_ms(); if (nobj) clEnqueueReleaseGLObjects(q, nobj, objs, 0, NULL, NULL);
        double e = now_ms(); clFlush(q);
        double f = now_ms();
        clFinish(q);
        double h = now_ms();
        if (r >= 3) { t[0] += c - b; t[1] += e - d; t[2] += f - e; t[3] += h - f; t[4] += h - a; gpu += gpuMs(ev); }
        clReleaseEvent(ev);
    }
    printf("%-30s acquire %.3f  release %.3f  clFlush %.3f  then clFinish %.3f | total %.3f, kernel on GPU %.3f ms\n", label,
           t[0] / reps, t[1] / reps, t[2] / reps, t[3] / reps, t[4] / reps, gpu / reps);
}

int main(void) { @autoreleasepool {
    CGLPixelFormatAttribute attrs[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                        kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(attrs, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    cl_context_properties p[] = { CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE, (cl_context_properties)CGLGetShareGroup(ctx), 0 };
    cl_int e; gCL = clCreateContext(p, 0, NULL, NULL, NULL, &e);
    clGetContextInfo(gCL, CL_CONTEXT_DEVICES, sizeof gDev, &gDev, NULL);
    cl_command_queue q = clCreateCommandQueue(gCL, gDev, CL_QUEUE_PROFILING_ENABLE, &e);
    cl_program pr = clCreateProgramWithSource(gCL, 1, &kSrc, NULL, &e);
    if ((e = clBuildProgram(pr, 1, &gDev, "", NULL, NULL))) { printf("build %d\n", e); return 1; }
    gSpin = clCreateKernel(pr, "spin", &e);
    gTouch = clCreateKernel(pr, "touch", &e);
    gBuf = clCreateBuffer(gCL, CL_MEM_READ_WRITE, 64 * 1024 * 4, NULL, &e);
    clSetKernelArg(gSpin, 0, sizeof gBuf, &gBuf);

    enum { N = 16 };
    GLuint tex[N]; cl_mem objs[N];
    glGenTextures(N, tex);
    for (int i = 0; i < N; i++) {
        glBindTexture(GL_TEXTURE_2D, tex[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    }
    glFinish();
    for (int i = 0; i < N; i++) objs[i] = clCreateFromGLTexture(gCL, CL_MEM_READ_WRITE, GL_TEXTURE_2D, 0, tex[i], &e);
    GLuint gb; glGenBuffers(1, &gb); glBindBuffer(GL_ARRAY_BUFFER, gb); glBufferData(GL_ARRAY_BUFFER, 1 << 20, NULL, GL_DYNAMIC_DRAW);
    glFinish();
    cl_mem bobj = clCreateFromGLBuffer(gCL, CL_MEM_READ_WRITE, gb, &e);

    printf("-- does release wait for the kernel? (spin iterations -> kernel GPU time)\n");
    bracket(q, objs, 0, 1, 50, "no GL objects, empty kernel");
    bracket(q, objs, 0, 20000, 20, "no GL objects, heavy kernel");
    bracket(q, objs, 1, 1, 50, "1 texture, empty kernel");
    bracket(q, objs, 1, 20000, 20, "1 texture, heavy kernel");
    printf("-- does release scale with the object count?\n");
    bracket(q, objs, 2, 1, 50, "2 textures");
    bracket(q, objs, 4, 1, 50, "4 textures");
    bracket(q, objs, 16, 1, 50, "16 textures");
    bracket(q, &bobj, 1, 1, 50, "1 GL buffer");

    printf("-- CL submission floor without GL objects (CPU per call, no finish in the loop)\n");
    size_t g = 64;
    int one = 1;
    clSetKernelArg(gSpin, 1, sizeof one, &one);
    clFinish(q);
    double t0 = now_ms();
    for (int i = 0; i < 500; i++) clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, NULL);
    double t1 = now_ms(); clFinish(q); double t2 = now_ms();
    printf("500 ndrange, no flush: enqueue %.4f ms each, final clFinish %.3f ms (%.4f per kernel)\n", (t1 - t0) / 500, t2 - t1,
           (t2 - t0) / 500);
    t0 = now_ms();
    for (int i = 0; i < 500; i++) { clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, NULL); clFlush(q); }
    t1 = now_ms(); clFinish(q); t2 = now_ms();
    printf("500 ndrange+clFlush: %.4f ms each, final clFinish %.3f ms\n", (t1 - t0) / 500, t2 - t1);
    t0 = now_ms();
    for (int i = 0; i < 500; i++) { clEnqueueAcquireGLObjects(q, 1, objs, 0, NULL, NULL); clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, NULL);
                                    clEnqueueReleaseGLObjects(q, 1, objs, 0, NULL, NULL); }
    t1 = now_ms(); clFinish(q); t2 = now_ms();
    printf("500 acquire+ndrange+release, no flush: %.4f ms each, final clFinish %.3f ms\n", (t1 - t0) / 500, t2 - t1);

    printf("-- release with an event, no flush: is the CPU released before the GPU is done?\n");
    int heavy = 20000;
    clSetKernelArg(gSpin, 1, sizeof heavy, &heavy);
    size_t gh = 64 * 1024;
    for (int r = 0; r < 3; r++) {
        cl_event rel;
        double a = now_ms();
        clEnqueueAcquireGLObjects(q, 1, objs, 0, NULL, NULL);
        clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &gh, NULL, 0, NULL, NULL);
        clEnqueueReleaseGLObjects(q, 1, objs, 0, NULL, &rel);
        double b = now_ms();
        cl_int st; clGetEventInfo(rel, CL_EVENT_COMMAND_EXECUTION_STATUS, sizeof st, &st, NULL);
        clFlush(q);
        double c = now_ms();
        clWaitForEvents(1, &rel);
        double d = now_ms();
        printf("enqueue %.3f ms (release status %d), clFlush %.3f, wait %.3f\n", b - a, st, c - b, d - c);
        clReleaseEvent(rel);
    }

    printf("-- is GL ordered after a released CL kernel on the GPU? (GL fence after a 71 ms kernel)\n");
    for (int r = 0; r < 3; r++) {
        cl_event kev;
        glFlush();
        clEnqueueAcquireGLObjects(q, 1, objs, 0, NULL, NULL);
        clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &gh, NULL, 0, NULL, &kev);
        clEnqueueReleaseGLObjects(q, 1, objs, 0, NULL, NULL);
        clFlush(q);
        // GL work on the released texture, then a fence: when does it signal?
        GLuint fbo; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[0], 0);
        glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glFlush();
        double b = now_ms();
        while (glClientWaitSync(fence, 0, 0) == GL_TIMEOUT_EXPIRED) {}
        double c = now_ms();
        cl_int st; clGetEventInfo(kev, CL_EVENT_COMMAND_EXECUTION_STATUS, sizeof st, &st, NULL);
        printf("GL fence signalled %.3f ms after issue; CL kernel status then %d (0 = complete)\n", c - b, st);
        clFinish(q);
        glDeleteSync(fence); glDeleteFramebuffers(1, &fbo); clReleaseEvent(kev);
    }
    printf("-- and an unrelated GL fence (no shared object touched) after the release\n");
    for (int r = 0; r < 2; r++) {
        cl_event kev;
        clEnqueueAcquireGLObjects(q, 1, objs, 0, NULL, NULL);
        clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &gh, NULL, 0, NULL, &kev);
        clEnqueueReleaseGLObjects(q, 1, objs, 0, NULL, NULL);
        clFlush(q);
        GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glFlush();
        double b = now_ms();
        while (glClientWaitSync(fence, 0, 0) == GL_TIMEOUT_EXPIRED) {}
        double c = now_ms();
        cl_int st; clGetEventInfo(kev, CL_EVENT_COMMAND_EXECUTION_STATUS, sizeof st, &st, NULL);
        printf("GL fence signalled %.3f ms after issue; CL kernel status then %d\n", c - b, st);
        clFinish(q); glDeleteSync(fence); clReleaseEvent(kev);
    }
    printf("-- incremental acquires inside one bracket, released together (1 submission?)\n");
    clSetKernelArg(gSpin, 1, sizeof one, &one);
    for (int r = 0; r < 3; r++) {
        double a = now_ms();
        clEnqueueAcquireGLObjects(q, 8, objs, 0, NULL, NULL);
        for (int k = 0; k < 8; k++) clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, NULL);
        double a1 = now_ms();
        clEnqueueReleaseGLObjects(q, 8, objs, 0, NULL, NULL);
        double a2 = now_ms();
        clFlush(q); clFinish(q);
        printf("upfront: 1 acquire of 8 + 8 kernels %.3f ms, one release of 8 %.3f\n", a1 - a, a2 - a1);
        a = now_ms();
        for (int k = 0; k < 8; k++) {
            clEnqueueAcquireGLObjects(q, 1, &objs[k], 0, NULL, NULL);
            clEnqueueNDRangeKernel(q, gSpin, 1, NULL, &g, NULL, 0, NULL, NULL);
        }
        double b = now_ms();
        clEnqueueReleaseGLObjects(q, 8, objs, 0, NULL, NULL);
        double c = now_ms();
        (void)a;
        clFlush(q);
        double d = now_ms();
        clFinish(q);
        printf("incremental: 8 acquire+kernel %.3f ms, one release of 8 %.3f, clFlush %.3f\n", b - a, c - b, d - c);
    }

    printf("-- out-of-order queue\n");
    cl_command_queue qo = clCreateCommandQueue(gCL, gDev, CL_QUEUE_OUT_OF_ORDER_EXEC_MODE_ENABLE | CL_QUEUE_PROFILING_ENABLE, &e);
    printf("create: %d\n", e);
    if (qo) bracket(qo, objs, 1, 1, 50, "1 texture, out-of-order queue");
    return 0;
}}
