import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final playbackDiagnostics = PlaybackDiagnostics();

/// A bounded transport trace. Recording must never delay or fail playback.
class PlaybackDiagnostics {
  static const eventLimit = 200;
  static const _channel = MethodChannel('tacto/playback_diagnostics');
  final List<Map<String, Object>> _events = [];
  Future<void> _writes = Future.value();

  void record(String stage, {String? trackId, Object? error}) {
    final event = <String, Object>{
      'timeMs': DateTime.now().millisecondsSinceEpoch,
      'stage': stage,
      if (trackId != null) 'trackId': trackId,
      if (error != null) 'errorType': error.runtimeType.toString(),
    };
    _events.add(event);
    if (_events.length > eventLimit) _events.removeAt(0);
    debugPrint('TactoAudio stage=$stage id=${trackId ?? '-'}'
        '${error == null ? '' : ' error=${error.runtimeType}'}');
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _writes = _writes.then((_) async {
        try {
          await _channel
              .invokeMethod<void>('record', event)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          // An unavailable diagnostics bridge must never affect transport.
        }
      });
    }
  }

  Future<String> exportReport({Map<String, Object?>? playback}) async {
    var writesFlushed = true;
    try {
      await _writes.timeout(const Duration(seconds: 2));
    } catch (_) {
      writesFlushed = false;
    }
    Map<String, dynamic> native = {
      'available': false,
      'writesFlushed': writesFlushed,
    };
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final snapshot = await _channel
            .invokeMapMethod<String, dynamic>('read')
            .timeout(const Duration(seconds: 2));
        if (snapshot != null) {
          native = {
            'available': true,
            'writesFlushed': writesFlushed,
            ...snapshot
          };
        }
      } catch (error) {
        native['errorType'] = error.runtimeType.toString();
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'tacto-playback-diagnostics-v1',
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': defaultTargetPlatform.name,
      if (playback != null) 'playback': playback,
      'dartEvents': List.of(_events),
      'native': native,
    });
  }
}
