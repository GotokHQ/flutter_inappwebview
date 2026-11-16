import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef _NativeScrollCallbackC =
    Bool Function(Int64 token, Int32 x, Int32 y, Float scrollRoomDp);

typedef FastScrollListener = void Function(int x, int y, double scrollRoomDp);

final class _Bindings {
  _Bindings(DynamicLibrary library)
    : initDartApi = library
          .lookupFunction<
            IntPtr Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('iaw_init_dart_api'),
      allocateToken = library
          .lookupFunction<Int64 Function(), int Function()>(
            'iaw_allocate_token',
          ),
      registerCallback = library
          .lookupFunction<Bool Function(UintPtr), bool Function(int)>(
            'iaw_register_scroll_callback',
          ),
      fastDispatchCount = library
          .lookupFunction<Int64 Function(), int Function()>(
            'iaw_fast_dispatch_count',
          );

  final int Function(Pointer<Void>) initDartApi;
  final int Function() allocateToken;
  final bool Function(int) registerCallback;
  final int Function() fastDispatchCount;
}

/// One WebView's listener, plus the zone it was registered in.
///
/// MethodChannel handlers run in the zone the bindings were initialized in,
/// while a native callback starts in the root zone. Running the listener in
/// its registration zone keeps error handling identical on both paths. The
/// arguments are parked in fields and [_runInZone] is created once, so
/// delivering an event allocates nothing.
final class _Registration {
  _Registration(this._listener) : _zone = Zone.current;

  final FastScrollListener _listener;
  final Zone _zone;
  int _x = 0;
  int _y = 0;
  double _scrollRoomDp = 0;

  late final void Function() _runInZone = () =>
      _listener(_x, _y, _scrollRoomDp);

  void dispatch(int x, int y, double scrollRoomDp) {
    if (identical(_zone, Zone.current)) {
      _listener(x, y, scrollRoomDp);
      return;
    }
    _x = x;
    _y = y;
    _scrollRoomDp = scrollRoomDp;
    _zone.run<void>(_runInZone);
  }
}

/// Receives `WebView.onScrollChanged` synchronously from the Android main
/// thread through JNI and a [NativeCallable.isolateLocal] callback, instead of
/// through a MethodChannel message.
///
/// This only delivers events when Flutter runs Dart on the Android main
/// thread (merged platform/UI thread). The native side checks that on every
/// event and otherwise reports the event as unhandled, so the plugin falls
/// back to the MethodChannel. Nothing here needs to know which path is live.
///
/// The event crosses the JNI boundary as primitives, so there are no JNI
/// references to release and nothing is allocated per event on the native
/// side. The Dart side allocates one timer per burst of events (see
/// [_requestEventLoopTurn]) and nothing else.
final class AndroidFastScrollBridge {
  AndroidFastScrollBridge._();

  static final Map<int, _Registration> _listeners = <int, _Registration>{};

  static bool _probed = false;
  static _Bindings? _bindings;

  // Created once and kept for the isolate's lifetime. Closing it while a
  // scroll event is being delivered would free the function the native side
  // is still executing.
  static NativeCallable<_NativeScrollCallbackC>? _callable;

  static _Bindings? _load() {
    if (_probed) return _bindings;
    _probed = true;
    if (!Platform.isAndroid) return null;
    try {
      final bindings = _Bindings(
        DynamicLibrary.open('libiaw_fast_scroll.so'),
      );
      if (bindings.initDartApi(NativeApi.initializeApiDLData) == 0) {
        _bindings = bindings;
      }
    } catch (_) {
      _bindings = null;
    }
    return _bindings;
  }

  /// Whether the native library is present and usable in this process.
  static bool get isSupported => _load() != null;

  /// Number of scroll events the native side has delivered synchronously
  /// since the process started. Stays at zero while events are travelling
  /// over the MethodChannel fallback.
  static int get fastDispatchCount => _load()?.fastDispatchCount() ?? 0;

  /// Returns a process-unique token identifying one WebView, or 0 when the
  /// fast path is unavailable.
  static int allocateToken() => _load()?.allocateToken() ?? 0;

  static void register(int token, FastScrollListener listener) {
    final bindings = _load();
    if (token <= 0 || bindings == null) return;
    if (_callable == null) {
      final callable = NativeCallable<_NativeScrollCallbackC>.isolateLocal(
        _onNativeScroll,
        exceptionalReturn: false,
      );
      if (!bindings.registerCallback(callable.nativeFunction.address)) {
        callable.close();
        return;
      }
      callable.keepIsolateAlive = false;
      _callable = callable;
    }
    _listeners[token] = _Registration(listener);
  }

  static void unregister(int token) {
    if (token <= 0) return;
    _listeners.remove(token);
  }

  static bool _onNativeScroll(int token, int x, int y, double scrollRoomDp) {
    final registration = _listeners[token];
    // Unknown token: let the native side fall back to the MethodChannel.
    if (registration == null) return false;
    try {
      registration.dispatch(x, y, scrollRoomDp);
    } catch (error, stackTrace) {
      // The event was delivered; returning false here would deliver it a
      // second time over the MethodChannel.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_inappwebview',
          context: ErrorDescription('while dispatching a WebView scroll event'),
        ),
      );
    }
    _requestEventLoopTurn();
    return true;
  }

  // The engine drains the microtask queue after each of its own tasks. A
  // native callback is not one of them, so an `await` or `then` inside a
  // scroll listener would sit until some unrelated task ran, which can be
  // over a second away while Flutter is idle and the page is scrolling. A
  // zero-delay timer gives the engine a task right after the current native
  // callback returns. One timer covers every event delivered before it fires.
  static bool _eventLoopTurnRequested = false;

  static void _requestEventLoopTurn() {
    if (_eventLoopTurnRequested) return;
    _eventLoopTurnRequested = true;
    // The root zone, so a test's fake clock cannot hold the timer back.
    Zone.root.createTimer(Duration.zero, _onEventLoopTurn);
  }

  static void _onEventLoopTurn() {
    _eventLoopTurnRequested = false;
  }
}
