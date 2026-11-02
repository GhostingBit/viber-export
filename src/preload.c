// preload.c — LD_PRELOAD interposer that captures the `PRAGMA hexkey` Viber issues when it
// opens an encrypted viber.db. Used by vc_runtime_keys to discover the key at runtime without
// a debugger (gdb is unreliable on a multithreaded Qt app).
//
// Build:  gcc -O2 -fPIC -shared -o preload.so preload.c -ldl
// Run:    VIBER_PRELOAD_LOG=/path/to/log LD_PRELOAD=preload.so Viber ...
//
// It hooks the *exported* Qt symbol QSqlQuery::exec(const QString&)
// (mangled _ZN9QSqlQuery4execERK7QString — survives Viber/Qt version changes) and appends any
// query containing "hexkey" to the log as:   HEXKEY: <query>
// The real implementation is then called, so Viber behaves normally.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>

static const char* logpath(void){
  const char* e = getenv("VIBER_PRELOAD_LOG");
  return (e && *e) ? e : NULL;   // no log target -> interposer is a no-op
}

/* QString layout (Qt6, verified empirically on this build):
   +0  : 8 bytes  (d pointer / flags)
   +8  : 8 bytes  = pointer to UTF-16LE data
   +16 : 8 bytes  = length in chars (qsizetype)
*/
static void log_qstring(const void* s){
  const uint8_t* p = (const uint8_t*)s;
  void*  data = *(void**)(p + 8);
  size_t len  = *(size_t*)(p + 16);
  if (!data || len == 0 || len > 8192) return;
  const uint16_t* u = (const uint16_t*)data;
  char* buf = (char*)malloc(len + 1);
  if (!buf) return;
  for (size_t i = 0; i < len; i++) buf[i] = (char)(u[i] & 0xff);
  buf[len] = 0;
  const char* lp = logpath();
  if (lp && strstr(buf, "hexkey")){
    FILE* f = fopen(lp, "a");
    if (f){ fprintf(f, "HEXKEY: %s\n", buf); fflush(f); fclose(f); }
  }
  free(buf);
}

/* bool QSqlQuery::exec(const QString&)  ->  _ZN9QSqlQuery4execERK7QString
   Member fn calling convention: rdi=this, rsi=&query */
bool _ZN9QSqlQuery4execERK7QString(void* self, const void* query){
  log_qstring(query);
  typedef bool (*real_t)(void*, const void*);
  static real_t real = NULL;
  if (!real) real = (real_t)dlsym(RTLD_NEXT, "_ZN9QSqlQuery4execERK7QString");
  if (real) return real(self, query);
  return 0;
}
