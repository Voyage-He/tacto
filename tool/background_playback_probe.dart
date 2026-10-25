import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/current_playlist.dart';
import 'package:listen2/src/provider/global/storage.dart';
import 'package:listen2/src/provider/repo/bilibili.dart';
import 'package:music_api/music_api.dart';
import 'package:listen2/src/provider/repo/track.dart';
import 'package:path_provider/path_provider.dart';
import 'package:listen2/src/view/page/player/player.page.dart';

late void Function(String, [Object?]) probeTrace;

class ProbeClientNotifier extends BilibiliClientNotifier {
  ProbeClientNotifier(this.client);
  final BilibiliClient client;
  @override
  Future<BilibiliClient> build() async => client;
}

class ProbeClient extends BilibiliClient {
  ProbeClient(super.box, this.bytes);
  final Uint8List bytes;
  @override
  Future<List<String>> getVideoInfo(String id) async {
    probeTrace('networkStart', 'metadata $id');
    await Future<void>.delayed(const Duration(seconds: 2));
    probeTrace('networkReady', 'metadata $id');
    return [id, id, 'Tacto native probe', 'file:///dev/null'];
  }

  @override
  Future<Stream> getAudioStream(String id) async {
    probeTrace('networkStart', 'audio $id');
    await Future<void>.delayed(const Duration(seconds: 3));
    probeTrace('networkReady', 'audio $id');
    return Stream<List<int>>.value(bytes);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationSupportDirectory();
  final directory = Directory('${root.path}/native-playback-probe');
  await directory.create(recursive: true);
  final log = File('${directory.path}/trace.jsonl');
  log.writeAsStringSync('');
  void trace(String event, [Object? detail]) {
    final data = jsonEncode({
      'at': DateTime.now().toIso8601String(),
      'event': event,
      'detail': detail,
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name
    });
    log.writeAsStringSync('$data\n', mode: FileMode.append, flush: true);
    debugPrint('NATIVE_PROBE $data');
  }

  probeTrace = trace;
  FlutterError.onError = (details) =>
      trace('flutterError', '${details.exception} ${details.stack}');
  Hive.init(directory.path);
  Hive.registerAdapter(CurrentPlaylistStateAdapter());
  Hive.registerAdapter(TrackAdapter());
  final setting = await Hive.openBox('setting');
  final value = await Hive.openBox('value');
  final binary = await Hive.openBox<Uint8List>('binary');
  final queueBox =
      await Hive.openBox<CurrentPlaylistState>('current_playlist_state');
  await queueBox.put(
      'default', const CurrentPlaylistState(index: 0, playlist: []));
  final storage =
      Storage(setting, value, binary, {'current_playlist_state': queueBox});
  final ids = ['native-probe-1', 'native-probe-2', 'native-probe-3'];
  final tracks = await Hive.openBox<Track>('tracks');
  for (final id in ids) {
    await tracks.delete(id);
  }
  await tracks.put(ids.first,
      Track(ids.first, ids.first, 'Tacto native probe', 'file:///dev/null'));
  final bytes = base64Decode(const String.fromEnvironment('TACTO_PROBE_AUDIO'));
  for (final id in ids) {
    await binary.delete(id);
  }
  await binary.put(ids.first, bytes);
  final container = ProviderContainer(overrides: [
    hiveStorageProvider.overrideWith((ref) async => storage),
    bilibiliClientNotifierProvider
        .overrideWith(() => ProbeClientNotifier(ProbeClient(value, bytes))),
  ]);
  await container.read(hiveStorageProvider.future);
  await container.read(bilibiliClientNotifierProvider.future);
  final handler = await container.read(audioHandlerProvider.future);
  await handler.setVolume(.05);
  container.read(playerStateNotifierProvider);
  handler.player.onPlayerStateChanged
      .listen((state) => trace('nativeState', state.name));
  handler.player.onPlayerComplete.listen((_) async {
    final id = handler.mediaItem.value?.id;
    trace('nativeComplete', id);
    final status = await const MethodChannel('tacto/audio_transition')
        .invokeMapMethod<String, dynamic>('status');
    trace('nativeLease', {'id': id, ...?status});
  });
  var previousSystemState = '';
  handler.playbackState.listen((state) async {
    final id = handler.mediaItem.value?.id;
    final key = '${state.playing}/${state.processingState.name}/$id';
    if (key == previousSystemState) return;
    previousSystemState = key;
    trace('systemState', {
      'playing': state.playing,
      'processing': state.processingState.name,
      'track': id
    });
    if (state.playing && state.processingState.name == 'ready') {
      final status = await const MethodChannel('tacto/audio_transition')
          .invokeMapMethod<String, dynamic>('status');
      trace('nowPlaying', {'id': id, ...?status});
    }
  });
  queueBox
      .watch()
      .listen((_) => trace('queueIndex', queueBox.get('default')?.index));
  runApp(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: Player(isHome: true)))));
  trace('starting', log.path);
  await container
      .read(currentPlaylistNotifierProvider.notifier)
      .play(ids.first, ids);
  trace('started');
}
