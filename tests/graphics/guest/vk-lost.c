/* vk-lost: what a Vulkan app sees when the host loses its Venus context.
 * Submits an empty batch with a fence and waits in a loop (2 s timeout; after the
 * poison without a timeout, like most apps). With --poison it calls
 * vkCreateShaderModule with codeSize 6 at the 10th round: invalid (not a multiple of
 * 4), which the host's venus decoder treats as fatal for the whole context. Prints one
 * JSON line per wait so a test can tell a hang from VK_ERROR_DEVICE_LOST or an abort.
 * Build: cc -O2 -o vk-lost vk-lost.c -lvulkan */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

static double now(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
   printf("{\"step\":\"%s\",\"result\":%d}\n", #x, r_); return 2; } } while (0)

int main(int argc, char **argv)
{
   int poison = argc > 1 && !strcmp(argv[1], "--poison");
   double t0 = now();
   setvbuf(stdout, NULL, _IOLBF, 0);

   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
   VkInstance inst;
   CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1;
   VkPhysicalDevice pd;
   VkResult er = vkEnumeratePhysicalDevices(inst, &n, &pd);
   if ((er != VK_SUCCESS && er != VK_INCOMPLETE) || n == 0) {
      printf("{\"step\":\"enumerate\",\"result\":%d}\n", er);
      return 2;
   }
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   printf("{\"device\":\"%s\"}\n", props.deviceName);

   float prio = 1.0f;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
   VkDevice dev;
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q;
   vkGetDeviceQueue(dev, 0, 0, &q);
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
   VkFence fence;
   CHECK(vkCreateFence(dev, &fci, NULL, &fence));

   int ok = 0, lost = 0, timeouts = 0, other = 0;
   for (int i = 0; i < 40; i++) {
      if (poison && i == 10) {
         uint32_t code[2] = { 0x07230203, 0 };
         VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                           .codeSize = 6, .pCode = code };
         VkShaderModule sm;
         VkResult r = vkCreateShaderModule(dev, &smci, NULL, &sm);
         printf("{\"step\":\"poison\",\"t\":%.3f,\"result\":%d}\n", now() - t0, r);
      }
      VkResult r = vkQueueSubmit(q, 0, NULL, fence);
      if (r == VK_SUCCESS)
         r = vkWaitForFences(dev, 1, &fence, VK_TRUE,
                             poison && i >= 10 ? UINT64_MAX : 2000000000ull);
      if (r == VK_SUCCESS)
         r = vkResetFences(dev, 1, &fence);
      printf("{\"i\":%d,\"t\":%.3f,\"result\":%d}\n", i, now() - t0, r);
      if (r == VK_SUCCESS) ok++;
      else if (r == VK_ERROR_DEVICE_LOST) { lost++; break; }
      else if (r == VK_TIMEOUT) timeouts++;
      else other++;
      struct timespec ts = { 0, 50000000 };
      nanosleep(&ts, NULL);
   }
   printf("{\"done\":true,\"t\":%.3f,\"ok\":%d,\"device_lost\":%d,\"timeouts\":%d,\"other\":%d}\n",
          now() - t0, ok, lost, timeouts, other);
   vkDestroyFence(dev, fence, NULL);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   return 0;
}
