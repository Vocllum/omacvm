// libFuzzer harness for omacvm-gestures' handshake (src/gestures/mac/omacvm-gestures.c):
// the input is what a VM sends on connect (hello line, then the reply line),
// fed to greet() over a socket pair. HOME points at a scratch dir holding a
// known Bridge token (also in gestures.dict), so the token path is reachable.
#define main gestures_main
#include "../../src/gestures/mac/omacvm-gestures.c"
#undef main

#define FUZZ_TOKEN "0123456789abcdef0123456789abcdef"

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  char dir[] = "/tmp/omacvm-fuzz-gestures-XXXXXX", path[1024];
  if (!mkdtemp(dir)) abort();
  setenv("HOME", dir, 1);
  snprintf(path, sizeof path, "%s/Library/Application Support/omacvm-bridge", dir);
  char cmd[1200]; snprintf(cmd, sizeof cmd, "mkdir -p '%s'", path); if (system(cmd)) abort();
  strcat(path, "/token");
  FILE *f = fopen(path, "w"); if (!f) abort();
  fputs(FUZZ_TOKEN "\n", f); fclose(f);
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) return 0;
  int one = 1; setsockopt(sv[1], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  if (size > 4096) size = 4096;
  if (size && write(sv[1], data, size) != (ssize_t)size) { close(sv[0]); close(sv[1]); return 0; }
  shutdown(sv[1], SHUT_WR);
  struct greetArg *g = malloc(sizeof *g);
  g->fd = sv[0]; g->net = 3; inet_pton(AF_INET, "10.211.55.5", &g->addr);
  __sync_fetch_and_add(&greeting, 1);
  greet(g);   // closes sv[0], or keeps it as a client until the next one replaces it
  close(sv[1]);
  return 0;
}
