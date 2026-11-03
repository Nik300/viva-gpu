// TeraScale Compute - OpenCL entry points used by the runtime and the core, resolved with dlopen when the core
// builds them in (TS_CL_DYNAMIC): OpenCL.framework is loaded only when the first kernel needs it, so processes
// that never run an OpenCL kernel (compute off, or GL-path kernels only) never load it. The C0 probes link
// OpenCL directly and see the plain functions.
#pragma once
#include <OpenCL/opencl.h>
#include <OpenCL/cl_gl_ext.h>
#include <stdbool.h>

#ifdef TS_CL_DYNAMIC
#define TS_CL_FUNCS(X) \
    X(cl_context, clCreateContext, (const cl_context_properties *, cl_uint, const cl_device_id *, \
                                    void (*)(const char *, const void *, size_t, void *), void *, cl_int *)) \
    X(cl_int, clGetContextInfo, (cl_context, cl_context_info, size_t, void *, size_t *)) \
    X(cl_int, clGetDeviceInfo, (cl_device_id, cl_device_info, size_t, void *, size_t *)) \
    X(cl_command_queue, clCreateCommandQueue, (cl_context, cl_device_id, cl_command_queue_properties, cl_int *)) \
    X(cl_int, clReleaseContext, (cl_context)) \
    X(cl_int, clReleaseCommandQueue, (cl_command_queue)) \
    X(cl_int, clFinish, (cl_command_queue)) \
    X(cl_int, clFlush, (cl_command_queue)) \
    X(cl_int, clReleaseMemObject, (cl_mem)) \
    X(cl_mem, clCreateFromGLTexture, (cl_context, cl_mem_flags, cl_GLenum, cl_GLint, cl_GLuint, cl_int *)) \
    X(cl_mem, clCreateFromGLBuffer, (cl_context, cl_mem_flags, cl_GLuint, cl_int *)) \
    X(cl_int, clEnqueueAcquireGLObjects, (cl_command_queue, cl_uint, const cl_mem *, cl_uint, const cl_event *, cl_event *)) \
    X(cl_int, clEnqueueReleaseGLObjects, (cl_command_queue, cl_uint, const cl_mem *, cl_uint, const cl_event *, cl_event *)) \
    X(cl_int, clEnqueueNDRangeKernel, (cl_command_queue, cl_kernel, cl_uint, const size_t *, const size_t *, const size_t *, \
                                       cl_uint, const cl_event *, cl_event *)) \
    X(cl_program, clCreateProgramWithSource, (cl_context, cl_uint, const char **, const size_t *, cl_int *)) \
    X(cl_int, clBuildProgram, (cl_program, cl_uint, const cl_device_id *, const char *, void (*)(cl_program, void *), void *)) \
    X(cl_int, clGetProgramBuildInfo, (cl_program, cl_device_id, cl_program_build_info, size_t, void *, size_t *)) \
    X(cl_int, clReleaseProgram, (cl_program)) \
    X(cl_kernel, clCreateKernel, (cl_program, const char *, cl_int *)) \
    X(cl_int, clReleaseKernel, (cl_kernel)) \
    X(cl_int, clGetKernelWorkGroupInfo, (cl_kernel, cl_device_id, cl_kernel_work_group_info, size_t, void *, size_t *)) \
    X(cl_int, clSetKernelArg, (cl_kernel, cl_uint, size_t, const void *)) \
    X(cl_sampler, clCreateSampler, (cl_context, cl_bool, cl_addressing_mode, cl_filter_mode, cl_int *)) \
    X(cl_int, clReleaseSampler, (cl_sampler)) \
    X(cl_int, clGetProgramInfo, (cl_program, cl_program_info, size_t, void *, size_t *)) \
    X(cl_program, clCreateProgramWithBinary, (cl_context, cl_uint, const cl_device_id *, const size_t *, const unsigned char **, \
                                              cl_int *, cl_int *)) \
    X(cl_int, clSetEventCallback, (cl_event, cl_int, void (*)(cl_event, cl_int, void *), void *)) \
    X(cl_int, clGetEventProfilingInfo, (cl_event, cl_profiling_info, size_t, void *, size_t *)) \
    X(cl_int, clReleaseEvent, (cl_event)) \
    X(cl_mem, clCreateImage, (cl_context, cl_mem_flags, const cl_image_format *, const cl_image_desc *, void *, cl_int *)) \
    X(cl_int, clGetEventInfo, (cl_event, cl_event_info, size_t, void *, size_t *)) \
    X(cl_int, clEnqueueMarkerWithWaitList, (cl_command_queue, cl_uint, const cl_event *, cl_event *)) \
    X(cl_int, clRetainCommandQueue, (cl_command_queue))

#define TS_CL_DECLARE(ret, name, args) extern ret (*ts_##name) args;
TS_CL_FUNCS(TS_CL_DECLARE)
#undef TS_CL_DECLARE

// Loads OpenCL.framework and resolves every function above (once; thread-safe). false if anything is missing.
bool TSCLApiLoad(const char **error);

#define clCreateContext ts_clCreateContext
#define clGetContextInfo ts_clGetContextInfo
#define clGetDeviceInfo ts_clGetDeviceInfo
#define clCreateCommandQueue ts_clCreateCommandQueue
#define clReleaseContext ts_clReleaseContext
#define clReleaseCommandQueue ts_clReleaseCommandQueue
#define clFinish ts_clFinish
#define clFlush ts_clFlush
#define clReleaseMemObject ts_clReleaseMemObject
#define clCreateFromGLTexture ts_clCreateFromGLTexture
#define clCreateFromGLBuffer ts_clCreateFromGLBuffer
#define clEnqueueAcquireGLObjects ts_clEnqueueAcquireGLObjects
#define clEnqueueReleaseGLObjects ts_clEnqueueReleaseGLObjects
#define clEnqueueNDRangeKernel ts_clEnqueueNDRangeKernel
#define clCreateProgramWithSource ts_clCreateProgramWithSource
#define clBuildProgram ts_clBuildProgram
#define clGetProgramBuildInfo ts_clGetProgramBuildInfo
#define clReleaseProgram ts_clReleaseProgram
#define clCreateKernel ts_clCreateKernel
#define clReleaseKernel ts_clReleaseKernel
#define clGetKernelWorkGroupInfo ts_clGetKernelWorkGroupInfo
#define clSetKernelArg ts_clSetKernelArg
#define clCreateSampler ts_clCreateSampler
#define clReleaseSampler ts_clReleaseSampler
#define clGetProgramInfo ts_clGetProgramInfo
#define clCreateProgramWithBinary ts_clCreateProgramWithBinary
#define clSetEventCallback ts_clSetEventCallback
#define clGetEventProfilingInfo ts_clGetEventProfilingInfo
#define clReleaseEvent ts_clReleaseEvent
#define clCreateImage ts_clCreateImage
#define clGetEventInfo ts_clGetEventInfo
#define clEnqueueMarkerWithWaitList ts_clEnqueueMarkerWithWaitList
#define clRetainCommandQueue ts_clRetainCommandQueue
#endif
