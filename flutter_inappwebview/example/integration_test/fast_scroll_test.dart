// Runs on an Android device or emulator:
//
//   flutter test integration_test/fast_scroll_test.dart -d <android device>
//
// Proves that WebView scroll events reach Dart synchronously through the
// native bridge (JNI + dart:ffi) instead of a MethodChannel message, that the
// MethodChannel fallback still works, and that neither path crashes.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// The bridge is an implementation detail of the Android package; the test
// reads its delivery counter to tell the two paths apart.
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:flutter_inappwebview_android/src/in_app_webview/_fast_scroll_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String _tallPage = '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>html, body { margin: 0; } #tall { height: 6000px; background: linear-gradient(#fff, #789); }</style>
</head>
<body><div id="tall">tall page</div></body>
</html>
''';

class _ScrollEvent {
  _ScrollEvent(this.y, this.scrollRoom, this.stack);

  final int y;
  final double? scrollRoom;
  final String stack;

  bool get cameThroughBridge => stack.contains('_onNativeScroll');
  bool get cameThroughChannel => stack.contains('_handleMethod');
}

class _Page {
  final List<_ScrollEvent> events = <_ScrollEvent>[];
  final Completer<InAppWebViewController> controller =
      Completer<InAppWebViewController>();
  final Completer<void> loaded = Completer<void>();

  Widget build({Key? key, InAppWebViewKeepAlive? keepAlive}) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: InAppWebView(
        key: key,
        keepAlive: keepAlive,
        initialData: InAppWebViewInitialData(data: _tallPage),
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        onWebViewCreated: (c) {
          if (!controller.isCompleted) controller.complete(c);
        },
        onLoadStop: (c, url) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onScrollChanged: (c, x, y) {
          events.add(
            _ScrollEvent(
              y,
              c.lastScrollRoomLogical,
              StackTrace.current.toString(),
            ),
          );
        },
      ),
    );
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for a scroll event.');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Waits until the page has a viewport.
///
/// The platform view is sized a few frames after it is created. Until then
/// the page is laid out at zero size, so its scroll range is not the one the
/// test is about.
Future<void> _waitForViewport(
  WidgetTester tester,
  InAppWebViewController controller,
) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final height = await controller.evaluateJavascript(
      source: 'window.innerHeight',
    );
    if (height is num && height > 0) {
      // One more frame so the compositor has reported the new scroll range.
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
    if (DateTime.now().isAfter(end)) {
      fail('The page never got a viewport.');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bool skip = kIsWeb || !Platform.isAndroid;

  testWidgets('native library loads', (tester) async {
    expect(AndroidFastScrollBridge.isSupported, isTrue);
  }, skip: skip);

  testWidgets('programmatic scroll is delivered through the bridge', (
    tester,
  ) async {
    final page = _Page();
    await tester.pumpWidget(page.build());
    final controller = await page.controller.future;
    await page.loaded.future;
    await _waitForViewport(tester, controller);

    final before = AndroidFastScrollBridge.fastDispatchCount;
    await controller.scrollTo(x: 0, y: 900);
    await _waitFor(tester, () => page.events.isNotEmpty);

    final event = page.events.last;
    expect(event.y, 900);
    expect(event.cameThroughBridge, isTrue, reason: event.stack);
    expect(event.cameThroughChannel, isFalse, reason: event.stack);
    expect(
      AndroidFastScrollBridge.fastDispatchCount - before,
      page.events.length,
      reason: 'every event must have used the bridge, none the channel',
    );

    // The scroll room that rides along with the event matches what the page
    // itself reports, so apps no longer need to ask the page mid-scroll.
    final fromPage = await controller.evaluateJavascript(
      source:
          'document.documentElement.scrollHeight - window.innerHeight',
    );
    expect(event.scrollRoom, isNotNull);
    expect(event.scrollRoom!, closeTo((fromPage as num).toDouble(), 2.0));
    expect(controller.lastScrollRoomLogical, event.scrollRoom);
  }, skip: skip);

  testWidgets('finger scrolling is delivered through the bridge', (
    tester,
  ) async {
    final page = _Page();
    await tester.pumpWidget(page.build());
    final controller = await page.controller.future;
    await page.loaded.future;
    await _waitForViewport(tester, controller);

    // Only count what the finger causes, not the page settling into its
    // viewport.
    page.events.clear();
    final before = AndroidFastScrollBridge.fastDispatchCount;
    await tester.timedDrag(
      find.byType(InAppWebView),
      const Offset(0, -500),
      const Duration(milliseconds: 500),
    );
    await _waitFor(tester, () => page.events.length >= 3);
    await tester.pump(const Duration(milliseconds: 800));

    // The finger must have moved the page. Where the fling then carries it is
    // up to the WebView (synthetic touches can even fling it back to the top).
    final positions = page.events.map((e) => e.y).toList();
    expect(
      positions.reduce((a, b) => a > b ? a : b),
      greaterThan(0),
      reason: 'positions: $positions',
    );
    expect(
      page.events.every((e) => e.cameThroughBridge && !e.cameThroughChannel),
      isTrue,
    );
    final fromPage = await controller.evaluateJavascript(
      source: 'document.documentElement.scrollHeight - window.innerHeight',
    );
    expect(
      page.events.last.scrollRoom!,
      closeTo((fromPage as num).toDouble(), 2.0),
    );
    expect(
      AndroidFastScrollBridge.fastDispatchCount - before,
      page.events.length,
    );
  }, skip: skip);

  testWidgets('async work started in a scroll handler resumes promptly', (
    tester,
  ) async {
    // A native callback runs outside the engine's task loop, so nothing
    // drains the microtask queue when it returns unless the bridge asks for
    // an event-loop turn. Flutter is deliberately left idle below while the
    // page scrolls itself; without that turn, the microtasks wait for the
    // delay to end. Debug builds have enough background activity to hide a
    // regression here, so also run this with `flutter drive --profile`.
    final delaysMs = <int>[];
    final controllerCompleter = Completer<InAppWebViewController>();
    final loaded = Completer<void>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: InAppWebView(
          initialData: InAppWebViewInitialData(data: _tallPage),
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
          onWebViewCreated: controllerCompleter.complete,
          onLoadStop: (c, url) {
            if (!loaded.isCompleted) loaded.complete();
          },
          onScrollChanged: (c, x, y) {
            final stopwatch = Stopwatch()..start();
            scheduleMicrotask(() => delaysMs.add(stopwatch.elapsedMilliseconds));
          },
        ),
      ),
    );
    final controller = await controllerCompleter.future;
    await loaded.future;
    await _waitForViewport(tester, controller);

    // The page scrolls 40 times over about a second, on its own timer.
    await controller.evaluateJavascript(
      source: '''
(function () {
  var steps = 0;
  var timer = setInterval(function () {
    window.scrollBy(0, 20);
    if (++steps >= 40) clearInterval(timer);
  }, 25);
})();
''',
    );
    await tester.pump(const Duration(milliseconds: 100));
    delaysMs.clear();
    // No pumping: only the page's own scroll events are running.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    // Lets anything that was left waiting run, so a failure reports how long.
    await tester.pump();

    expect(delaysMs.length, greaterThan(10));
    expect(
      delaysMs.reduce((a, b) => a > b ? a : b),
      lessThan(250),
      reason: 'microtask delays (ms): $delaysMs',
    );
  }, skip: skip);

  testWidgets('a throwing scroll handler is reported once and survives', (
    tester,
  ) async {
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    var calls = 0;
    final controllerCompleter = Completer<InAppWebViewController>();
    final loaded = Completer<void>();
    try {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: InAppWebView(
            initialData: InAppWebViewInitialData(data: _tallPage),
            onWebViewCreated: controllerCompleter.complete,
            onLoadStop: (c, url) {
              if (!loaded.isCompleted) loaded.complete();
            },
            onScrollChanged: (c, x, y) {
              calls++;
              throw StateError('scroll handler failed');
            },
          ),
        ),
      );
      final controller = await controllerCompleter.future;
      await loaded.future;
      await _waitForViewport(tester, controller);

      await controller.scrollTo(x: 0, y: 400);
      await _waitFor(tester, () => calls > 0);
      await tester.pump(const Duration(milliseconds: 500));
    } finally {
      FlutterError.onError = previousOnError;
    }

    // Delivered exactly once: not retried over the MethodChannel.
    expect(calls, 1);
    expect(reported, hasLength(1));
    expect(reported.single.exception, isStateError);
  }, skip: skip);

  testWidgets('disposing a WebView stops delivery and a new one still works', (
    tester,
  ) async {
    final first = _Page();
    await tester.pumpWidget(first.build(key: const ValueKey('first')));
    final firstController = await first.controller.future;
    await first.loaded.future;
    await _waitForViewport(tester, firstController);
    await firstController.scrollTo(x: 0, y: 300);
    await _waitFor(tester, () => first.events.isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    final afterDispose = first.events.length;

    final second = _Page();
    await tester.pumpWidget(second.build(key: const ValueKey('second')));
    final secondController = await second.controller.future;
    await second.loaded.future;
    await _waitForViewport(tester, secondController);
    await secondController.scrollTo(x: 0, y: 700);
    await _waitFor(tester, () => second.events.isNotEmpty);

    expect(first.events.length, afterDispose);
    expect(second.events.last.y, 700);
    expect(second.events.every((e) => e.cameThroughBridge), isTrue);
  }, skip: skip);

  testWidgets('a kept-alive WebView keeps using the bridge when re-attached', (
    tester,
  ) async {
    final keepAlive = InAppWebViewKeepAlive();
    final first = _Page();
    await tester.pumpWidget(
      first.build(key: const ValueKey('ka-1'), keepAlive: keepAlive),
    );
    final firstController = await first.controller.future;
    await first.loaded.future;
    await _waitForViewport(tester, firstController);
    await firstController.scrollTo(x: 0, y: 200);
    await _waitFor(tester, () => first.events.isNotEmpty);
    expect(first.events.every((e) => e.cameThroughBridge), isTrue);

    // Detach: the native WebView survives, its Dart controller does not.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));

    final second = _Page();
    await tester.pumpWidget(
      second.build(key: const ValueKey('ka-2'), keepAlive: keepAlive),
    );
    final secondController = await second.controller.future;
    await _waitForViewport(tester, secondController);
    await secondController.scrollTo(x: 0, y: 1200);
    await _waitFor(tester, () => second.events.isNotEmpty);

    expect(second.events.last.y, 1200);
    expect(second.events.every((e) => e.cameThroughBridge), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await InAppWebViewController.disposeKeepAlive(keepAlive);
  }, skip: skip);

  testWidgets('a WebView without a token falls back to the MethodChannel', (
    tester,
  ) async {
    final events = <_ScrollEvent>[];
    final loaded = Completer<void>();
    final headless = HeadlessInAppWebView(
      initialSize: const Size(360, 640),
      initialData: InAppWebViewInitialData(data: _tallPage),
      onLoadStop: (c, url) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onScrollChanged: (c, x, y) {
        events.add(
          _ScrollEvent(
            y,
            c.lastScrollRoomLogical,
            StackTrace.current.toString(),
          ),
        );
      },
    );
    await headless.run();
    try {
      await loaded.future;
      await tester.pump(const Duration(milliseconds: 300));

      final before = AndroidFastScrollBridge.fastDispatchCount;
      await headless.webViewController!.scrollTo(x: 0, y: 500);
      await _waitFor(tester, () => events.isNotEmpty);

      expect(events.last.y, 500);
      expect(events.last.cameThroughChannel, isTrue, reason: events.last.stack);
      expect(AndroidFastScrollBridge.fastDispatchCount, before);
      // The scroll room still arrives, as a MethodChannel argument.
      expect(events.last.scrollRoom, isNotNull);
      expect(events.last.scrollRoom!, greaterThan(320));
    } finally {
      await headless.dispose();
    }
  }, skip: skip);
}
