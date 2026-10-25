import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listen2/src/playback_diagnostics.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tacto/playback_diagnostics');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('report keeps a bounded recent history and excludes raw error contents',
      () async {
    final diagnostics = PlaybackDiagnostics();
    for (var i = 0; i < PlaybackDiagnostics.eventLimit + 3; i++) {
      diagnostics.record('event-$i',
          trackId: 'track', error: StateError('private-cookie-or-signed-url'));
    }
    final text =
        await diagnostics.exportReport(playback: {'state': 'completed'});
    final report = jsonDecode(text) as Map;
    final events = report['dartEvents'] as List;
    expect(events, hasLength(PlaybackDiagnostics.eventLimit));
    expect(events.first['stage'], 'event-3');
    expect(events.last['errorType'], 'StateError');
    expect(text, isNot(contains('private-cookie-or-signed-url')));
    expect(report['playback']['state'], 'completed');
  });

  test(
      'iOS export flushes transport records before reading persisted native events',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final firstWrite = Completer<void>();
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'record' && calls.length == 1) await firstWrite.future;
      if (call.method == 'read') {
        return {
          'appVersion': 'test-version',
          'events': [
            {'source': 'native', 'stage': 'native-complete'}
          ],
        };
      }
      return null;
    });
    final diagnostics = PlaybackDiagnostics();
    diagnostics.record('metadata-loading', trackId: 'song');
    diagnostics.record('audio-ready', trackId: 'song');
    final pending = diagnostics.exportReport();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['record']);
    firstWrite.complete();
    final report = jsonDecode(await pending) as Map;
    expect(calls, ['record', 'record', 'read']);
    expect(report['native']['available'], isTrue);
    expect(report['native']['events'].single['stage'], 'native-complete');
  });

  test('native diagnostics failure leaves playback recording and export usable',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'unavailable'));
    final diagnostics = PlaybackDiagnostics();
    diagnostics.record('native-complete', trackId: 'song');
    final report = jsonDecode(await diagnostics.exportReport()) as Map;
    expect(report['dartEvents'].single['stage'], 'native-complete');
    expect(report['native']['available'], isFalse);
    expect(report['native']['errorType'], 'PlatformException');
  });

  testWidgets('a hung native bridge still allows exporting the local trace',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final pending = Completer<Object?>();
    try {
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => pending.future);
      final diagnostics = PlaybackDiagnostics();
      diagnostics.record('native-complete', trackId: 'song');
      String? copied;
      final exporting =
          diagnostics.exportReport().then((value) => copied = value);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(copied, isNotNull);
      final report = jsonDecode(copied!) as Map;
      expect(report['dartEvents'].single['stage'], 'native-complete');
      expect(report['native']['available'], isFalse);
      expect(report['native']['errorType'], 'TimeoutException');
      pending.complete(null);
      await tester.pump();
      await exporting;
    } finally {
      if (!pending.isCompleted) pending.complete(null);
      debugDefaultTargetPlatformOverride = null;
      await tester.pump();
    }
  });
}
