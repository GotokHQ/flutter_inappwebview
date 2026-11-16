package com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview;

import androidx.annotation.Keep;

/**
 * Delivers {@code WebView.onScrollChanged} to Dart synchronously through JNI and a Dart FFI
 * callback, skipping the MethodChannel hop.
 *
 * <p>{@link #dispatchScroll} returns {@code false} whenever the native side cannot prove the
 * calling thread may run the Dart callback (library missing, no listener, threads not merged,
 * isolate gone). Callers must then fall back to the MethodChannel.
 */
@Keep
public final class FastScrollBridge {
  private static final boolean LIBRARY_LOADED;

  static {
    boolean loaded = false;
    try {
      System.loadLibrary("iaw_fast_scroll");
      loaded = true;
    } catch (Throwable ignored) {
      // Host JVM tests and ABIs without the native library use the MethodChannel path.
    }
    LIBRARY_LOADED = loaded;
  }

  private FastScrollBridge() {}

  public static boolean dispatchScroll(long token, int x, int y, float scrollRoomDp) {
    if (!LIBRARY_LOADED || token == 0L) {
      return false;
    }
    return nativeDispatchScroll(token, x, y, scrollRoomDp);
  }

  private static native boolean nativeDispatchScroll(
      long token, int x, int y, float scrollRoomDp);
}
