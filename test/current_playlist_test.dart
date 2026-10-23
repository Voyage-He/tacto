import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:listen2/src/provider/global/current_playlist.dart';
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/provider/global/storage.dart';
import 'package:listen2/src/provider/repo/track.dart';

class _Playback extends PlayerStateNotifier {
  final plays = <(String, bool)>[];
  Completer<void>? pending;
  Completer<void>? started;
  Object? error;
  bool stopBeforeLoad = false;

  @override
  PlayerState build() => PlayerState(
      state: ap.PlayerState.playing,
      track: Track('middle', 'Middle', 'Artist', ''));

  void select(String? id, ap.PlayerState playbackState) => state = PlayerState(
      state: playbackState,
      track: id == null ? null : Track(id, id, 'Artist', ''));

  @override
  Future<void> playTrackById(String trackId, {bool autoplay = true}) async {
    plays.add((trackId, autoplay));
    started?.complete();
    if (stopBeforeLoad) {
      await Future<void>.value();
      select(state.track?.bvid, ap.PlayerState.stopped);
    }
    await pending?.future;
    if (error != null) throw error!;
    select(trackId, autoplay ? ap.PlayerState.playing : ap.PlayerState.paused);
  }
}

void main() {
  late Directory directory;
  late Storage storage;
  late Box<CurrentPlaylistState> queueBox;
  late ProviderContainer container;
  late _Playback playback;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listen2-queue-test-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(CurrentPlaylistStateAdapter());
    }
    final value = await Hive.openBox('value');
    queueBox =
        await Hive.openBox<CurrentPlaylistState>('current_playlist_state');
    await queueBox.put(
        'default',
        const CurrentPlaylistState(
            index: 1, playlist: ['first', 'middle', 'last']));
    storage = Storage(value, value, await Hive.openBox<Uint8List>('binary'),
        {'current_playlist_state': queueBox});
    playback = _Playback();
    container = ProviderContainer(overrides: [
      hiveStorageProvider.overrideWith((ref) async => storage),
      playerStateNotifierProvider.overrideWith(() => playback),
    ]);
    await container.read(hiveStorageProvider.future);
    container.read(playerStateNotifierProvider);
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final enabled in [null, true, false]) {
    test('startup restores the saved queue with autoplay setting $enabled',
        () async {
      if (enabled != null) {
        await container
            .read(autoplayOnStartupProvider.notifier)
            .setAutoplay(enabled);
      }
      playback.select(null, ap.PlayerState.stopped);
      final queue = container.read(currentPlaylistNotifierProvider);
      await container.pump();
      expect(queue.index, 1);
      expect(queue.playlist, ['first', 'middle', 'last']);
      expect(playback.plays, [('middle', enabled ?? true)]);
      expect(container.read(playerStateNotifierProvider).state,
          enabled == false ? ap.PlayerState.paused : ap.PlayerState.playing);
    });
  }

  test('startup preference does not interrupt playback or block manual play',
      () async {
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(false);
    playback.select(null, ap.PlayerState.stopped);
    final subscription =
        container.listen(currentPlaylistNotifierProvider, (_, __) {});
    addTearDown(subscription.close);
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    await container.pump();
    final paused = container.read(playerStateNotifierProvider);
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(true);
    await container.pump();
    expect(container.read(playerStateNotifierProvider), same(paused));
    expect(playback.plays, [('middle', false)]);
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(false);
    await queue.play('middle', ['first', 'middle', 'last']);
    await container.pump();
    expect(playback.plays.last, ('middle', true));
    playback.select('middle', ap.PlayerState.completed);
    await container
        .read(currentPlaylistNotifierProvider.notifier)
        .onTrackCompleted('middle');
    await container.pump();
    await container.pump();
    expect(playback.plays.last, ('last', true));
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.playing);
  });

  test('next and previous use the active queue and persist the selected index',
      () async {
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    expect(await queue.skip(1), isTrue);
    expect(playback.plays, [('last', true)]);
    expect(container.read(currentPlaylistNotifierProvider).index, 2);
    expect(queueBox.get('default')!.index, 2);
    expect(await queue.skip(1), isFalse);
    expect(playback.plays, hasLength(1));
    expect(await queue.skip(-1), isTrue);
    expect(await queue.skip(-1), isTrue);
    expect(playback.plays, [('last', true), ('middle', true), ('first', true)]);
    expect(queueBox.get('default')!.index, 0);
    expect(queueBox.get('default')!.playlist, ['first', 'middle', 'last']);
    expect(await queue.skip(-1), isFalse);
    expect(playback.plays, hasLength(3));
  });

  test('skipping a paused track keeps the next track paused', () async {
    playback.select('middle', ap.PlayerState.paused);
    expect(
        await container.read(currentPlaylistNotifierProvider.notifier).skip(1),
        isTrue);
    expect(playback.plays, [('last', false)]);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.paused);
  });

  test('skip follows the mounted record even if the saved index is stale',
      () async {
    await queueBox.put(
        'default',
        const CurrentPlaylistState(
            index: 0, playlist: ['first', 'middle', 'last']));
    expect(
        await container.read(currentPlaylistNotifierProvider.notifier).skip(1),
        isTrue);
    expect(playback.plays, [('last', true)]);
  });

  test('empty queues, missing records and invalid directions do not play',
      () async {
    await queueBox.put(
        'default', const CurrentPlaylistState(index: 0, playlist: []));
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    expect(await queue.skip(1), isFalse);
    playback.select(null, ap.PlayerState.paused);
    expect(await queue.skip(-1), isFalse);
    playback.select('missing', ap.PlayerState.playing);
    expect(await queue.skip(1), isFalse);
    expect(await queue.skip(0), isFalse);
    expect(playback.plays, isEmpty);
  });

  test('repeated skip requests do not overlap and failed loads can be retried',
      () async {
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    playback.pending = Completer<void>();
    final first = queue.skip(1);
    expect(await queue.skip(1), isFalse);
    playback.pending!.complete();
    expect(await first, isTrue);
    expect(playback.plays, [('last', true)]);
    playback.error = StateError('audio unavailable');
    await expectLater(queue.skip(-1), throwsStateError);
    playback.error = null;
    expect(await queue.skip(-1), isTrue);
    expect(container.read(playerStateNotifierProvider).track!.bvid, 'middle');
    expect(queueBox.get('default')!.index, 1);
  });
  test('completion follows the actual song when the saved queue index is stale',
      () async {
    await queueBox.put(
        'default',
        const CurrentPlaylistState(
            index: 0, playlist: ['first', 'middle', 'last']));
    final subscription =
        container.listen(currentPlaylistNotifierProvider, (_, __) {});
    addTearDown(subscription.close);
    playback.select('middle', ap.PlayerState.completed);
    await container
        .read(currentPlaylistNotifierProvider.notifier)
        .onTrackCompleted('middle');
    await container.pump();
    await container.pump();
    expect(playback.plays, [('last', true)]);
    expect(queueBox.get('default')!.index, 2);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.playing);
  });

  test('finishing the final song stops even when the saved index is stale',
      () async {
    await queueBox.put(
        'default',
        const CurrentPlaylistState(
            index: 0, playlist: ['first', 'middle', 'last']));
    playback.select('last', ap.PlayerState.playing);
    final subscription =
        container.listen(currentPlaylistNotifierProvider, (_, __) {});
    addTearDown(subscription.close);
    playback.select('last', ap.PlayerState.completed);
    await container
        .read(currentPlaylistNotifierProvider.notifier)
        .onTrackCompleted('last');
    await container.pump();
    await container.pump();
    expect(playback.plays, isEmpty);
    expect(container.read(currentPlaylistNotifierProvider).index, 2);
    expect(queueBox.get('default')!.index, 2);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.completed);
  });

  for (final startup in [null, false]) {
    test(
        'completion loads the next song once through stopped state with startup autoplay $startup',
        () async {
      if (startup != null) {
        await container
            .read(autoplayOnStartupProvider.notifier)
            .setAutoplay(startup);
      }
      final subscription =
          container.listen(currentPlaylistNotifierProvider, (_, __) {});
      addTearDown(subscription.close);
      playback.pending = Completer<void>();
      playback.started = Completer<void>();
      playback.stopBeforeLoad = true;
      playback.select('middle', ap.PlayerState.completed);
      final completion = container
          .read(currentPlaylistNotifierProvider.notifier)
          .onTrackCompleted('middle');
      await playback.started!.future.timeout(const Duration(seconds: 5));
      final requests = List.of(playback.plays);
      playback.pending!.complete();
      await completion;
      expect(requests, [('last', true)]);
      expect(playback.plays, [('last', true)]);
      expect(container.read(playerStateNotifierProvider).state,
          ap.PlayerState.playing);
      expect(queueBox.get('default')!.index, 2);
    });
  }

  test('completion advances without UI listeners or a provider frame pump',
      () async {
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    playback.select('middle', ap.PlayerState.completed);
    await queue.onTrackCompleted('middle');
    expect(playback.plays, [('last', true)]);
  });

  test('completion of an old source cannot advance the current record',
      () async {
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    await queue.onTrackCompleted('first');
    expect(playback.plays, isEmpty);
    expect(queueBox.get('default')!.index, 1);
  });

  test('completion and manual skipping share the same navigation guard',
      () async {
    final queue = container.read(currentPlaylistNotifierProvider.notifier);
    playback.pending = Completer<void>();
    playback.select('middle', ap.PlayerState.completed);
    final first = queue.onTrackCompleted('middle');
    await queue.onTrackCompleted('middle');
    expect(await queue.skip(1), isFalse);
    playback.pending!.complete();
    await first;
    expect(playback.plays, [('last', true)]);
  });

  test('adjacent entries of the same song still autoplay the next queue entry',
      () async {
    await queueBox.put(
        'default',
        const CurrentPlaylistState(
            index: 0, playlist: ['middle', 'middle', 'last']));
    final subscription =
        container.listen(currentPlaylistNotifierProvider, (_, __) {});
    addTearDown(subscription.close);
    playback.select('middle', ap.PlayerState.completed);
    await container
        .read(currentPlaylistNotifierProvider.notifier)
        .onTrackCompleted('middle');
    await container.pump();
    await container.pump();
    expect(playback.plays, [('middle', true)]);
    expect(queueBox.get('default')!.index, 1);
    expect(container.read(playerStateNotifierProvider).state,
        ap.PlayerState.playing);
  });
}
