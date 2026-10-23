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
    final currentPlaylistState = ref.storage.custom["current_playlist_state"]!
        .get('default',
            defaultValue: const CurrentPlaylistState(index: 0, playlist: []));
    // Completion is handled by the audio service, without waiting for a UI frame.
    if (ref.read(playerStateNotifierProvider).track != null) initilized = true;
    if (initilized) return currentPlaylistState;
    initilized = true;
    return load(autoplay: ref.read(autoplayOnStartupProvider));
  }

  Future<void> play(String trackId, List<String> playlistTrackIds,
      {bool autoplay = true}) async {
    final index = playlistTrackIds.indexOf(trackId);
    if (index < 0) return;
    await _playAt(index, playlistTrackIds, autoplay: autoplay);
  }

  Future<void> _playAt(int index, List<String> ids,
      {required bool autoplay}) async {
    final next = CurrentPlaylistState(index: index, playlist: List.of(ids));
    await ref.storage.custom["current_playlist_state"]!.put('default', next);
    state = next;
    await ref
        .read(playerStateNotifierProvider.notifier)
        .playTrackById(next.currentTrackId, autoplay: autoplay);
  }

  int _activeIndex(String trackId) {
    final index = state.index;
    final ids = state.playlist;
    return index >= 0 && index < ids.length && ids[index] == trackId
        ? index
        : ids.indexOf(trackId);
  }

  /// Called directly by the native completion stream, including in the background.
  Future<void> onTrackCompleted(String trackId) async {
    if (_skipping) return;
    final playback = ref.read(playerStateNotifierProvider);
    if (playback.track?.bvid != trackId || playback.loading) return;
    final index = _activeIndex(trackId);
    if (index < 0) return;
    final ids = List<String>.of(state.playlist);
    _skipping = true;
    try {
      if (index == ids.length - 1) {
        if (state.index != index) {
          final last = CurrentPlaylistState(index: index, playlist: ids);
          await ref.storage.custom["current_playlist_state"]!
              .put('default', last);
          state = last;
        }
        return;
      }
      await _playAt(index + 1, ids, autoplay: true);
    } finally {
      _skipping = false;
    }
  }

  /// Share queue navigation between the record gestures and system controls.
  Future<bool> skip(int direction) async {
    if (_skipping || (direction != -1 && direction != 1)) return false;
    final playlist = List<String>.of(state.playlist);
    final playback = ref.read(playerStateNotifierProvider);
    final track = playback.track;
    if (track == null) return false;
    final index = _activeIndex(track.bvid);
    final next = index + direction;
    if (index < 0 || next < 0 || next >= playlist.length) return false;
    _skipping = true;
    try {
      await _playAt(next, playlist,
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
    return currentPlaylistState;
  }
}
