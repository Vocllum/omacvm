// cltest.c: OpenCL smoke test - saxpy on 16M floats + reduction, checked against the CPU, timed.
#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#define CK(x) do { cl_int e_ = (x); if (e_ != CL_SUCCESS) { printf("FAIL %s = %d (line %d)\n", #x, e_, __LINE__); return 1; } } while (0)
static const char *src =
"__kernel void saxpy(float a, __global const float *x, __global float *y) {\n"
"  size_t i = get_global_id(0); y[i] = a * x[i] + y[i]; }\n"
"__kernel void sum(__global const float *x, __global float *out, __local float *tmp, uint n) {\n"
"  size_t l = get_local_id(0), g = get_global_id(0); float s = 0;\n"
"  for (size_t i = g; i < n; i += get_global_size(0)) s += x[i];\n"
"  tmp[l] = s; barrier(CLK_LOCAL_MEM_FENCE);\n"
"  for (size_t k = get_local_size(0) / 2; k > 0; k >>= 1) { if (l < k) tmp[l] += tmp[l + k]; barrier(CLK_LOCAL_MEM_FENCE); }\n"
"  if (l == 0) out[get_group_id(0)] = tmp[0]; }\n";
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
int main(void) {
  cl_platform_id p; cl_device_id d; cl_int e; char name[256];
  CK(clGetPlatformIDs(1, &p, NULL)); CK(clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 1, &d, NULL));
  clGetDeviceInfo(d, CL_DEVICE_NAME, sizeof name, name, NULL); printf("device: %s\n", name);
  cl_context c = clCreateContext(NULL, 1, &d, NULL, NULL, &e); CK(e);
  cl_command_queue q = clCreateCommandQueueWithProperties(c, d, NULL, &e); CK(e);
  cl_program pr = clCreateProgramWithSource(c, 1, &src, NULL, &e); CK(e);
  if (clBuildProgram(pr, 1, &d, "", NULL, NULL) != CL_SUCCESS) { char log[8192]; clGetProgramBuildInfo(pr, d, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); printf("build log: %s\n", log); return 1; }
  const size_t n = 16 << 20; float *x = malloc(n * 4), *y = malloc(n * 4), *r = malloc(n * 4);
  for (size_t i = 0; i < n; i++) { x[i] = (float)(i % 1000) * 0.001f; y[i] = (float)(i % 7); }
  cl_mem bx = clCreateBuffer(c, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, n * 4, x, &e); CK(e);
  cl_mem by = clCreateBuffer(c, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, n * 4, y, &e); CK(e);
  cl_kernel k = clCreateKernel(pr, "saxpy", &e); CK(e); float a = 2.5f;
  CK(clSetKernelArg(k, 0, 4, &a)); CK(clSetKernelArg(k, 1, sizeof bx, &bx)); CK(clSetKernelArg(k, 2, sizeof by, &by));
  CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL)); CK(clFinish(q));
  int reps = 50; double t0 = now();
  for (int i = 0; i < reps; i++) CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL));
  CK(clFinish(q)); double dt = now() - t0;
  CK(clEnqueueReadBuffer(q, by, CL_TRUE, 0, n * 4, r, 0, NULL, NULL));
  size_t bad = 0; for (size_t i = 0; i < n; i++) { float ref = y[i]; for (int j = 0; j < reps + 1; j++) ref = a * x[i] + ref; if (fabsf(ref - r[i]) > 1e-3f * fabsf(ref) + 1e-3f) bad++; }
  printf("saxpy: %zu mismatches of %zu; %.1f GB/s (%d x 16M, %.3f s)\n", bad, n, 12.0 * n * reps / dt / 1e9, reps, dt);
  size_t gs = 256 * 256, ls = 256; cl_mem bo = clCreateBuffer(c, CL_MEM_WRITE_ONLY, 256 * 4, NULL, &e); CK(e);
  cl_kernel ks = clCreateKernel(pr, "sum", &e); CK(e); cl_uint nn = n;
  CK(clSetKernelArg(ks, 0, sizeof bx, &bx)); CK(clSetKernelArg(ks, 1, sizeof bo, &bo)); CK(clSetKernelArg(ks, 2, 256 * 4, NULL)); CK(clSetKernelArg(ks, 3, 4, &nn));
  CK(clEnqueueNDRangeKernel(q, ks, 1, NULL, &gs, &ls, 0, NULL, NULL)); float part[256];
  CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, sizeof part, part, 0, NULL, NULL));
  double gsum = 0, csum = 0; for (int i = 0; i < 256; i++) gsum += part[i]; for (size_t i = 0; i < n; i++) csum += x[i];
  printf("sum: gpu %.1f cpu %.1f rel err %.2e\n", gsum, csum, fabs(gsum - csum) / csum);
  printf("%s\n", bad == 0 && fabs(gsum - csum) / csum < 1e-4 ? "PASS" : "FAIL");
  return 0;
}
