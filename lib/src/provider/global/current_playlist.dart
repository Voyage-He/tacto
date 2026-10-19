import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/ref_extensions.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'current_playlist.g.dart';

@HiveType(typeId: 2)
class CurrentPlaylistState {
  @HiveField(0)
  final int index;
  @HiveField(1)
  final List<String> playlist;
  const CurrentPlaylistState({required this.index, required this.playlist});

  String get currentTrackId => playlist[index];

  bool get hasNext => index < playlist.length - 1;

  CurrentPlaylistState playNext() {
    if (!hasNext) return this;
    return CurrentPlaylistState(index: index + 1, playlist: playlist);
  }

  CurrentPlaylistState insertTrackId(String trackId) {
    return CurrentPlaylistState(
        index: index, playlist: playlist..insert(index + 1, trackId));
  }
}

@Riverpod(keepAlive: true)
class CurrentPlaylistNotifier extends _$CurrentPlaylistNotifier {
  bool initilized = false;
  bool _skipping = false;

  @override
  CurrentPlaylistState build() {
    final playerBackState =
        ref.watch(playerStateNotifierProvider.select((state) => state.state));
    final currentPlaylistState = ref.storage.custom["current_playlist_state"]!
        .get('default',
            defaultValue: const CurrentPlaylistState(index: 0, playlist: []));
    debugPrint("current play list provider build");
    debugPrint('playerBackState: $playerBackState');
    final trackId = ref.read(playerStateNotifierProvider).track?.bvid;
    if (trackId != null) initilized = true;
    if (playerBackState == ap.PlayerState.completed) {
      final ids = currentPlaylistState.playlist;
      final savedIndex = currentPlaylistState.index;
      final index = savedIndex >= 0 &&
              savedIndex < ids.length &&
              ids[savedIndex] == trackId
          ? savedIndex
          : ids.indexOf(trackId ?? '');
      if (index < 0) return currentPlaylistState;
      final active = CurrentPlaylistState(index: index, playlist: ids);
      final next = active.hasNext ? active.playNext() : active;
      if (next.index != savedIndex) {
        ref.storage.custom["current_playlist_state"]!.put('default', next);
      }
      if (!active.hasNext) return next;
      return load(autoplay: true);
    } else if (playerBackState == ap.PlayerState.playing) {
      return currentPlaylistState;
    }

    if (initilized) return currentPlaylistState;
    initilized = true;
    return load(autoplay: ref.read(autoplayOnStartupProvider));
  }

  Future<void> play(String trackId, List<String> playlistTrackIds,
      {bool autoplay = true}) async {
    final index = playlistTrackIds.indexOf(trackId);
    if (index < 0) return;
    final next =
        CurrentPlaylistState(index: index, playlist: List.of(playlistTrackIds));
    await ref.storage.custom["current_playlist_state"]!.put('default', next);
    state = next;
    await ref
        .read(playerStateNotifierProvider.notifier)
        .playTrackById(trackId, autoplay: autoplay);
  }

  /// Share queue navigation between the record gestures and system controls.
  Future<bool> skip(int direction) async {
    if (_skipping || (direction != -1 && direction != 1)) return false;
    final playlist = List<String>.of(state.playlist);
    final playback = ref.read(playerStateNotifierProvider);
    final track = playback.track;
    if (track == null) return false;
    final index = playlist.indexOf(track.bvid);
    final next = index + direction;
    if (index < 0 || next < 0 || next >= playlist.length) return false;
    _skipping = true;
    try {
      await play(playlist[next], playlist,
          autoplay: playback.state == ap.PlayerState.playing);
      return true;
    } finally {
      _skipping = false;
    }
  }

  void setNext(String trackId) {
    ref.storage.custom["current_playlist_state"]!
        .put('default', state.insertTrackId(trackId));
    load();
  }

  CurrentPlaylistState load({bool autoplay = true}) {
    final currentPlaylistState = ref.storage.custom["current_playlist_state"]!
        .get('default',
            defaultValue: const CurrentPlaylistState(index: 0, playlist: []));

    if (currentPlaylistState.playlist.isEmpty) return currentPlaylistState;
    final playback = ref.read(playerStateNotifierProvider);
    if (currentPlaylistState.currentTrackId == playback.track?.bvid &&
        playback.state != ap.PlayerState.completed) {
      return currentPlaylistState;
    }

    ref
        .read(playerStateNotifierProvider.notifier)
        .playTrackById(currentPlaylistState.currentTrackId, autoplay: autoplay);
    debugPrint('load call time');
    return currentPlaylistState;
  }
}
