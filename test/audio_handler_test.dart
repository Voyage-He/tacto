import 'dart:async';

import 'package:audio_service/audio_service.dart'
    show MediaControl, MediaItem, AudioProcessingState;
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listen2/src/provider/global/player.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('xyz.luan/audioplayers');
  const sessionChannel = MethodChannel('com.ryanheise.audio_session');
  const codec = StandardMethodCodec();
  late AudioHandler handler;
  late List<MethodCall> calls;
  late List<int> skips;
  late List<String> completions;
  Completer<void>? completionPending;
  bool failSeek = false;

  void emit(String event, [Object? value]) {
    binding.channelBuffers.push(
      'xyz.luan/audioplayers/events/${handler.player.playerId}',
      codec.encodeSuccessEnvelope({'event': event, 'value': value}),
      (_) {},
    );
  }

  setUp(() async {
    calls = [];
    skips = [];
    completions = [];
    completionPending = null;
    failSeek = false;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, (_) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(playerChannel,
        (call) async {
      calls.add(call);
      if (call.method == 'seek' && failSeek) {
        throw PlatformException(code: 'seek_failed');
      }
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      if (call.method == 'setSourceUrl') emit('audio.onPrepared', true);
      return null;
    });
    handler = AudioHandler(
      onSkip: (direction) async => skips.add(direction),
      onComplete: (trackId) async {
        completions.add(trackId);
        await completionPending?.future;
      },
    );
    await handler.initialize();
  });

  tearDown(() async {
    await handler.dispose();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(playerChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
  });

  test('system controls operate the player and update Now Playing state',
      () async {
    await handler.player.setSource(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.play();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'resume');
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls, [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
      MediaControl.stop,
    ]);
    expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);

    await handler.pause();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'pause');
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);

    await handler.seek(const Duration(seconds: 15));
    expect(calls.last.method, 'seek');
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 15));
    await handler.stop();
    await Future<void>.delayed(Duration.zero);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('system previous and next controls reach the queue in order', () async {
    await handler.skipToPrevious();
    await handler.skipToNext();
    expect(skips, [-1, 1]);
  });

  test('native completion reaches the queue without a widget frame', () async {
    handler.mediaItem.add(const MediaItem(id: 'song', title: 'Song'));
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    emit('audio.onComplete');
    await Future<void>.delayed(Duration.zero);
    expect(completions, ['song']);
  });

  test('duplicate completions cannot overlap while the next song loads',
      () async {
    handler.mediaItem.add(const MediaItem(id: 'song', title: 'Song'));
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    completionPending = Completer<void>();
    emit('audio.onComplete');
    emit('audio.onComplete');
    await Future<void>.delayed(Duration.zero);
    expect(completions, ['song']);
    completionPending!.complete();
    await Future<void>.delayed(Duration.zero);
    handler.mediaItem.add(const MediaItem(id: 'next', title: 'Next'));
    await handler.player.release();
    await handler.load(ap.DeviceFileSource('/cache/next.m4a'));
    emit('audio.onComplete');
    await Future<void>.delayed(Duration.zero);
    expect(completions, ['song', 'next']);
  });

  test('explicit pause and stop never request automatic queue advancement',
      () async {
    handler.mediaItem.add(const MediaItem(id: 'song', title: 'Song'));
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.pause();
    await handler.stop();
    await Future<void>.delayed(Duration.zero);
    expect(completions, isEmpty);
  });

  test('mounting a record with the needle raised never starts audio', () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'), autoplay: false);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
    expect(handler.player.source, isNotNull);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.player.state, ap.PlayerState.paused);
    await handler.play();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'resume');
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('native duration and position reach lock screen metadata', () async {
    handler.mediaItem.add(const MediaItem(id: 'song', title: 'Song'));
    emit('audio.onDuration', 90000);
    emit('audio.onCurrentPosition', 12000);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value!.duration, const Duration(seconds: 90));
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 12));
  });

  test('completed tracks cannot be resumed with no source', () async {
    await handler.player.setSource(ap.DeviceFileSource('/cache/song.m4a'));
    emit('audio.onComplete');
    await Future<void>.delayed(Duration.zero);
    final count = calls.where((call) => call.method == 'resume').length;
    await handler.play();
    expect(calls.where((call) => call.method == 'resume').length, count);
    expect(handler.playbackState.value.processingState,
        AudioProcessingState.completed);
  });

  test(
      'holding a playing record fades and pauses, then seeks and restores playback',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    calls.clear();
    await handler.beginScrub();
    await Future<void>.delayed(Duration.zero);
    expect(handler.player.state, ap.PlayerState.paused);
    expect(handler.player.volume, 0);
    expect(handler.playbackState.value.playing, isFalse);
    expect(await handler.finishScrub(const Duration(seconds: 42)), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(handler.player.state, ap.PlayerState.playing);
    expect(handler.player.volume, 1);
    final commands = calls.map((call) => call.method).toList();
    expect(commands.indexOf('pause'), lessThan(commands.indexOf('seek')));
    expect(commands.indexOf('seek'), lessThan(commands.indexOf('resume')));
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 42));
  });

  test('scrubbing a paused record keeps it paused and preserves its volume',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'), autoplay: false);
    await handler.player.setVolume(.35);
    calls.clear();
    await handler.beginScrub();
    await handler.finishScrub(const Duration(seconds: 12));
    expect(handler.player.state, ap.PlayerState.paused);
    expect(handler.player.volume, .35);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
  });

  test('volume changes during a hold stay silent and apply when released',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.beginScrub();
    await handler.setVolume(.2);
    expect(handler.player.volume, 0);
    await handler.finishScrub(const Duration(seconds: 12));
    expect(handler.player.state, ap.PlayerState.playing);
    expect(handler.player.volume, .2);
  });

  test('cancelling a preview resumes without seeking', () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.beginScrub();
    calls.clear();
    await handler.finishScrub();
    expect(handler.player.state, ap.PlayerState.playing);
    expect(handler.player.volume, 1);
    expect(calls.where((call) => call.method == 'seek'), isEmpty);
  });

  test('explicit pause during the fade prevents a gesture from resuming music',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    calls.clear();
    final holding = handler.beginScrub();
    await handler.pause();
    await holding;
    expect(await handler.finishScrub(const Duration(seconds: 12)), isFalse);
    expect(handler.player.state, ap.PlayerState.paused);
    expect(handler.player.volume, 1);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
    expect(calls.where((call) => call.method == 'seek'), isEmpty);
  });

  test(
      'replacing a record cancels the preview before the new source is mounted',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.beginScrub();
    await handler.load(ap.DeviceFileSource('/cache/next.m4a'), autoplay: false);
    calls.clear();
    expect(await handler.finishScrub(const Duration(seconds: 12)), isFalse);
    expect(handler.player.state, ap.PlayerState.paused);
    expect(handler.player.volume, 1);
    expect(calls, isEmpty);
  });

  test('seek failure restores volume and the original playback state',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.beginScrub();
    failSeek = true;
    await expectLater(handler.finishScrub(const Duration(seconds: 12)),
        throwsA(isA<PlatformException>()));
    expect(handler.player.volume, 1);
    expect(handler.player.state, ap.PlayerState.playing);
    expect(await handler.finishScrub(), isFalse);
  });

  test(
      'explicit pause while a preview resumes remains the final transport state',
      () async {
    await handler.load(ap.DeviceFileSource('/cache/song.m4a'));
    await handler.beginScrub();
    final finishing = handler.finishScrub(const Duration(seconds: 12));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await handler.pause();
    await finishing;
    expect(handler.player.state, ap.PlayerState.paused);
    expect(handler.player.volume, 1);
  });
}
