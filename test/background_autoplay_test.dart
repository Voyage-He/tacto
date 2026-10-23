import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:listen2/src/provider/global/current_playlist.dart';
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/provider/global/storage.dart';
import 'package:listen2/src/provider/repo/track.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('xyz.luan/audioplayers');
  const sessionChannel = MethodChannel('com.ryanheise.audio_session');
  const codec = StandardMethodCodec();
  late Directory directory;
  late Box<CurrentPlaylistState> queueBox;
  late ProviderContainer container;
  late AudioHandler handler;
  late Completer<void> advanced;
  late List<String> commands;

  void emit(String event, [Object? value]) {
    binding.channelBuffers.push(
      'xyz.luan/audioplayers/events/${handler.player.playerId}',
      codec.encodeSuccessEnvelope({'event': event, 'value': value}),
      (_) {},
    );
  }

  setUp(() async {
    commands = [];
    directory = await Directory.systemTemp.createTemp('tacto-background-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(CurrentPlaylistStateAdapter());
    }
    final value = await Hive.openBox('value');
    queueBox =
        await Hive.openBox<CurrentPlaylistState>('current_playlist_state');
    final storage = Storage(
        value,
        value,
        await Hive.openBox<Uint8List>('binary'),
        {'current_playlist_state': queueBox});
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, (_) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(playerChannel,
        (call) async {
      commands.add(call.method);
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      if (call.method == 'setSourceBytes') emit('audio.onPrepared', true);
      return null;
    });
    handler = AudioHandler(onComplete: (trackId) async {
      try {
        await container
            .read(currentPlaylistNotifierProvider.notifier)
            .onTrackCompleted(trackId);
        advanced.complete();
      } catch (error, stack) {
        advanced.completeError(error, stack);
      }
    });
    await handler.initialize();
    container = ProviderContainer(overrides: [
      hiveStorageProvider.overrideWith((ref) async => storage),
      audioHandlerProvider.overrideWith((ref) async => handler),
      for (final id in ['first', 'middle', 'last'])
        trackProvider(id)
            .overrideWith((ref) async => Track(id, id, 'Artist', '')),
    ]);
    await container.read(hiveStorageProvider.future);
    for (final id in ['first', 'middle', 'last']) {
      await storage.binary.put(id, Uint8List(4));
    }
    await container.read(audioHandlerProvider.future);
    container.read(playerStateNotifierProvider);
    // The startup preference must not suppress continuation of an active queue.
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(false);
    await container
        .read(currentPlaylistNotifierProvider.notifier)
        .play('first', ['first', 'middle', 'last']);
  });

  tearDown(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    container.dispose();
    await handler.dispose();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(playerChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('native completion keeps advancing a background queue without UI frames',
      () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(binding.framesEnabled, isFalse);
    for (final (index, id) in [(1, 'middle'), (2, 'last')]) {
      advanced = Completer<void>();
      emit('audio.onComplete');
      await advanced.future.timeout(const Duration(seconds: 5));
      // Drain native player state streams; do not pump widgets or providers.
      await Future<void>.delayed(Duration.zero);
      final playback = container.read(playerStateNotifierProvider);
      expect(playback.track!.bvid, id);
      expect(playback.state, ap.PlayerState.playing);
      expect(handler.player.state, ap.PlayerState.playing);
      expect(queueBox.get('default')!.index, index);
      expect(binding.framesEnabled, isFalse);
    }
    expect(commands.where((command) => command == 'resume'), hasLength(3));

    advanced = Completer<void>();
    emit('audio.onComplete');
    await advanced.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.completed);
    expect(queueBox.get('default')!.index, 2);
    expect(commands.where((command) => command == 'resume'), hasLength(3));
  });
}
