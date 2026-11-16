// Synchronous WebView scroll dispatch: Java -> JNI -> Dart, with no
// MethodChannel hop.
//
// The Dart side hands us a `NativeCallable.isolateLocal` function pointer.
// Such a pointer may only be invoked by a thread that is *inside* the isolate
// that created it; invoking it anywhere else aborts the process. WebView
// scroll events arrive on the Android main thread from the Looper, where no
// isolate is entered, so every dispatch has to:
//
//   1. prove the calling thread owns the isolate (true on Flutter's merged
//      platform/UI thread, false otherwise),
//   2. enter the isolate, invoke the callback, and exit again.
//
// Whenever that cannot be proven we return JNI_FALSE and the Java caller
// falls back to the MethodChannel path, so the worst case is the old
// behavior, never a crash.

#include <jni.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "dart_api_dl.h"

typedef bool (*IawScrollCallback)(
    int64_t token,
    int32_t x,
    int32_t y,
    float scroll_room_dp);

typedef struct {
  uintptr_t callback;
  Dart_Isolate isolate;
  Dart_Port main_port;
} IawRegistration;

// One registration slot, owned by the isolate that registered last. A second
// isolate that registers takes the slot over; views owned by the first one
// then report "not handled" (tokens are process-unique) and use the
// MethodChannel path instead.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static IawRegistration g_registration = {0, NULL, 0};
static bool g_api_ready = false;

static _Atomic int64_t g_next_token = 1;
static _Atomic int64_t g_fast_dispatch_count = 0;

#define IAW_EXPORT __attribute__((visibility("default"))) __attribute__((used))

// Must be called once per isolate with `NativeApi.initializeApiDLData` before
// anything else. Returns 0 on success.
IAW_EXPORT intptr_t iaw_init_dart_api(void* data) {
  if (data == NULL) {
    return -1;
  }
  pthread_mutex_lock(&g_lock);
  intptr_t result = Dart_InitializeApiDL(data);
  if (result == 0 &&
      (Dart_CurrentIsolate_DL == NULL || Dart_EnterIsolate_DL == NULL ||
       Dart_ExitIsolate_DL == NULL || Dart_GetMainPortId_DL == NULL ||
       Dart_GetCurrentThreadOwnsIsolate_DL == NULL)) {
    // Runtime is too old to tell us whether this thread owns the isolate.
    result = -2;
  }
  g_api_ready = result == 0;
  pthread_mutex_unlock(&g_lock);
  return result;
}

// Tokens are allocated here, not in Dart, so they stay unique across
// isolates and hot restarts.
IAW_EXPORT int64_t iaw_allocate_token(void) {
  return atomic_fetch_add_explicit(&g_next_token, 1, memory_order_relaxed);
}

// Called from Dart, inside the isolate that created `callback_addr`.
// Returns false when the callback could not be registered. There is no
// unregister: the registration lives as long as its isolate, and a dead
// isolate is detected at dispatch time.
IAW_EXPORT bool iaw_register_scroll_callback(uintptr_t callback_addr) {
  if (callback_addr == 0) {
    return false;
  }
  pthread_mutex_lock(&g_lock);
  bool registered = false;
  if (g_api_ready) {
    Dart_Isolate isolate = Dart_CurrentIsolate_DL();
    if (isolate != NULL) {
      g_registration.callback = callback_addr;
      g_registration.isolate = isolate;
      g_registration.main_port = Dart_GetMainPortId_DL();
      registered = true;
    }
  }
  pthread_mutex_unlock(&g_lock);
  return registered;
}

// Number of scroll events delivered synchronously since process start.
IAW_EXPORT int64_t iaw_fast_dispatch_count(void) {
  return atomic_load_explicit(&g_fast_dispatch_count, memory_order_relaxed);
}

JNIEXPORT jboolean JNICALL
Java_com_pichillilorenzo_flutter_1inappwebview_1android_webview_in_1app_1webview_FastScrollBridge_nativeDispatchScroll(
    JNIEnv* env,
    jclass clazz,
    jlong token,
    jint x,
    jint y,
    jfloat scroll_room_dp) {
  (void)env;
  (void)clazz;

  // Snapshot under the lock, call outside it: the Dart callback is free to
  // register or unregister while it runs.
  pthread_mutex_lock(&g_lock);
  IawRegistration reg = g_registration;
  bool api_ready = g_api_ready;
  pthread_mutex_unlock(&g_lock);

  if (!api_ready || reg.callback == 0 || reg.isolate == NULL) {
    return JNI_FALSE;
  }

  IawScrollCallback callback = (IawScrollCallback)reg.callback;
  Dart_Isolate current = Dart_CurrentIsolate_DL();
  bool handled;

  if (current != NULL) {
    // Already inside an isolate (a scroll triggered synchronously from Dart).
    // Only safe if it is the isolate that registered; the port comparison
    // rules out a dead isolate whose address was reused.
    if (current != reg.isolate || Dart_GetMainPortId_DL() != reg.main_port) {
      return JNI_FALSE;
    }
    handled = callback(
        (int64_t)token, (int32_t)x, (int32_t)y, (float)scroll_room_dp);
  } else {
    // Not inside any isolate. Entering is only legal from the thread that
    // owns the isolate; this is also false once the isolate is gone (hot
    // restart, engine destroyed), which is what retires a stale pointer.
    if (!Dart_GetCurrentThreadOwnsIsolate_DL(reg.main_port)) {
      return JNI_FALSE;
    }
    Dart_EnterIsolate_DL(reg.isolate);
    handled = callback(
        (int64_t)token, (int32_t)x, (int32_t)y, (float)scroll_room_dp);
    Dart_ExitIsolate_DL();
  }

  if (handled) {
    atomic_fetch_add_explicit(&g_fast_dispatch_count, 1, memory_order_relaxed);
    return JNI_TRUE;
  }
  return JNI_FALSE;
}
