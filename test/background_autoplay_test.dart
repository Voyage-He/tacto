import 'dart:io';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:audio_service/audio_service.dart' as system;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:listen2/src/provider/global/current_playlist.dart';
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/provider/global/storage.dart';
import 'package:listen2/src/provider/repo/track.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('xyz.luan/audioplayers');
  const sessionChannel = MethodChannel('com.ryanheise.audio_session');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const codec = StandardMethodCodec();
  const serviceClient =
      MethodChannel('com.ryanheise.audio_service.client.methods');
  const serviceHandler =
      MethodChannel('com.ryanheise.audio_service.handler.methods');
  late Directory directory;
  late Box<CurrentPlaylistState> queueBox;
  late ProviderContainer container;
  late AudioHandler handler;
  late List<MethodCall> serviceCalls;
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
    serviceCalls = [];
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(serviceClient, (_) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(serviceHandler,
        (call) async {
      serviceCalls.add(call);
      return null;
    });
    directory = await Directory.systemTemp.createTemp('tacto-background-');
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.setDatabasesPath(directory.path);
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
    container = ProviderContainer(overrides: [
      hiveStorageProvider.overrideWith((ref) async => storage),
      for (final id in ['first', 'middle', 'last'])
        trackProvider(id).overrideWith((ref) async =>
            Track(id, id, 'Artist', 'file:///tmp/tacto-cover.png')),
    ]);
    await container.read(hiveStorageProvider.future);
    for (final id in ['first', 'middle', 'last']) {
      await storage.binary.put(id, Uint8List(4));
    }
    handler = await container.read(audioHandlerProvider.future);
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
    await Future<void>.delayed(Duration.zero);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(playerChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(serviceClient, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(serviceHandler, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('background completion preserves the actual system audio service',
      () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(binding.framesEnabled, isFalse);
    for (final (index, id) in [(1, 'middle'), (2, 'last')]) {
      final playing = handler.playbackState.firstWhere((state) =>
          state.playing &&
          state.processingState == system.AudioProcessingState.ready &&
          handler.mediaItem.value?.id == id);
      emit('audio.onComplete');
      await playing.timeout(const Duration(seconds: 5));
      // Drain platform messages; do not pump widgets or providers.
      await Future<void>.delayed(Duration.zero);
      final playback = container.read(playerStateNotifierProvider);
      expect(playback.track!.bvid, id);
      expect(playback.state, ap.PlayerState.playing);
      expect(queueBox.get('default')!.index, index);
      expect(binding.framesEnabled, isFalse);
      expect(
          serviceCalls.where((call) => call.method == 'stopService'), isEmpty,
          reason: 'Switching tracks must not clear iOS Now Playing');
    }
    expect(commands.where((command) => command == 'resume'), hasLength(3));
    expect(
        commands.where((command) => command == 'release' || command == 'stop'),
        isEmpty);
    final systemItems =
        serviceCalls.where((call) => call.method == 'setMediaItem');
    expect((systemItems.last.arguments as Map)['mediaItem']['id'], 'last');

    final completed = handler.playbackState.firstWhere((state) =>
        state.processingState == system.AudioProcessingState.completed);
    emit('audio.onComplete');
    await completed.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.completed);
    expect(queueBox.get('default')!.index, 2);
    expect(commands.where((command) => command == 'resume'), hasLength(3));
  });
}
