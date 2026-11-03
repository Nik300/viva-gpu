// Compute C0 probe: OpenCL platforms/devices and capabilities, then one kernel round trip on the GPU.
// Build: clang -framework OpenCL tests/compute/clprobe.c -o build/clprobe
#include <OpenCL/opencl.h>
#include <stdio.h>
int main(void) {
  cl_platform_id p; cl_uint n; if (clGetPlatformIDs(1,&p,&n) || !n) { puts("no platform"); return 1; }
  cl_device_id ds[4]; cl_uint nd; clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 4, ds, &nd);
  for (cl_uint i=0;i<nd;i++){ char b[4096]; cl_ulong u; size_t s, wi[3]; cl_bool bo; cl_uint ui;
    clGetDeviceInfo(ds[i],CL_DEVICE_NAME,sizeof b,b,0); printf("== %s\n",b);
    clGetDeviceInfo(ds[i],CL_DEVICE_VERSION,sizeof b,b,0); printf("version %s\n",b);
    clGetDeviceInfo(ds[i],CL_DEVICE_OPENCL_C_VERSION,sizeof b,b,0); printf("C %s\n",b);
    clGetDeviceInfo(ds[i],CL_DRIVER_VERSION,sizeof b,b,0); printf("driver %s\n",b);
    clGetDeviceInfo(ds[i],CL_DEVICE_EXTENSIONS,sizeof b,b,0); printf("ext %s\n",b);
    clGetDeviceInfo(ds[i],CL_DEVICE_LOCAL_MEM_SIZE,sizeof u,&u,0); printf("local %llu\n",u);
    clGetDeviceInfo(ds[i],CL_DEVICE_MAX_WORK_GROUP_SIZE,sizeof s,&s,0); printf("wg %zu\n",s);
    clGetDeviceInfo(ds[i],CL_DEVICE_IMAGE_SUPPORT,sizeof bo,&bo,0); printf("images %d\n",bo);
    clGetDeviceInfo(ds[i],CL_DEVICE_MAX_COMPUTE_UNITS,sizeof ui,&ui,0); printf("CUs %u\n",ui);
    clGetDeviceInfo(ds[i],CL_DEVICE_MAX_WRITE_IMAGE_ARGS,sizeof ui,&ui,0); printf("write imgs %u\n",ui);
    clGetDeviceInfo(ds[i],CL_DEVICE_MAX_READ_IMAGE_ARGS,sizeof ui,&ui,0); printf("read imgs %u\n",ui);
    clGetDeviceInfo(ds[i],CL_DEVICE_HALF_FP_CONFIG,sizeof u,&u,0); printf("half cfg %llx\n",u);
  }
  // tiny kernel round trip on GPU
  cl_device_id gd; if (clGetDeviceIDs(p, CL_DEVICE_TYPE_GPU, 1, &gd, 0)) { puts("no GPU device"); return 0; }
  cl_int e; cl_context c = clCreateContext(0,1,&gd,0,0,&e); cl_command_queue q = clCreateCommandQueue(c,gd,0,&e);
  const char *src = "__kernel void k(__global float *o){ size_t i=get_global_id(0); o[i]=i*2.0f; }";
  cl_program pr = clCreateProgramWithSource(c,1,&src,0,&e); e = clBuildProgram(pr,1,&gd,0,0,0); printf("build %d\n",e);
  cl_kernel k = clCreateKernel(pr,"k",&e); cl_mem m = clCreateBuffer(c,CL_MEM_WRITE_ONLY,1024*4,0,&e);
  clSetKernelArg(k,0,sizeof m,&m); size_t g=1024; e=clEnqueueNDRangeKernel(q,k,1,0,&g,0,0,0,0); float r[1024];
  clEnqueueReadBuffer(q,m,CL_TRUE,0,sizeof r,r,0,0,0); printf("enqueue %d r[1023]=%g\n",e,r[1023]);
}
