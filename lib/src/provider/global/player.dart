import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:listen2/src/provider/global/current_playlist.dart';
import 'package:listen2/src/provider/repo/track.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'player.g.dart';

void _traceAudio(String stage, {String? trackId, Object? error}) {
  // Transport stages only: no credentials, request headers or signed media URLs.
  debugPrint('TactoAudio stage=$stage id=${trackId ?? '-'}'
      '${error == null ? '' : ' error=${error.runtimeType}'}');
}

class PlayerState {
  ap.PlayerState state;
  Duration now;
  Duration length;
  Track? track;
  bool loading;

  PlayerState(
      {this.state = ap.PlayerState.stopped,
      this.now = Duration.zero,
      this.length = Duration.zero,
      this.track,
      this.loading = false});

  PlayerState copyWith(
      {ap.PlayerState? state,
      Duration? length,
      Duration? now,
      Track? track,
      bool? loading}) {
    return PlayerState(
        state: state ?? this.state,
        length: length ?? this.length,
        now: now ?? this.now,
        track: track ?? this.track,
        loading: loading ?? this.loading);
  }
}

class _RecordScrub {
  _RecordScrub(this.wasPlaying, this.volume);
  final bool wasPlaying;
  double volume;
  Future<void> work = Future.value();
}

/// Connects the player to iOS Now Playing and Android media controls.
class AudioHandler extends BaseAudioHandler {
  AudioHandler({
    Future<void> Function(int direction)? onSkip,
    Future<void> Function(String trackId)? onComplete,
  })  : _onSkip = onSkip,
        _onComplete = onComplete;

  final Future<void> Function(int direction)? _onSkip;
  final Future<void> Function(String trackId)? _onComplete;
  bool _handlingCompletion = false;
  bool _loadingSource = false;
  bool _playWhenReady = false;
  bool _stopped = false;
  static const _transitionChannel = MethodChannel('tacto/audio_transition');
  String? _tailGuardTrackId;
  final player = ap.AudioPlayer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _resumeAfterInterruption = false;
  bool _ducked = false;
  _RecordScrub? _scrub;

  Future<void> beginScrub() {
    if (_scrub != null) return _scrub!.work;
    if (player.source == null) return Future.value();
    final session =
        _RecordScrub(player.state == ap.PlayerState.playing, player.volume);
    _scrub = session;
    session.work = _holdRecord(session);
    return session.work;
  }

  Future<void> _holdRecord(_RecordScrub session) async {
    if (!session.wasPlaying) return;
    try {
      for (final factor in [.75, .5, .25, 0.0]) {
        if (_scrub != session) return;
        await player.setVolume(session.volume * factor);
        if (factor > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      if (_scrub == session) await player.pause();
    } catch (_) {
      if (_scrub == session) {
        _scrub = null;
        await player.setVolume(session.volume);
      }
      rethrow;
    }
  }

  /// Complete or cancel the preview, preserving the state before the hand touched it.
  Future<bool> finishScrub([Duration? target]) async {
    final session = _scrub;
    if (session == null) return false;
    final held = session.work;
    var applied = false;
    session.work = () async {
      try {
        await held;
        if (_scrub != session) return;
        if (target != null) {
          await _seekPosition(target);
          applied = true;
        }
      } finally {
        if (_scrub == session) {
          try {
            if (session.wasPlaying) {
              await player.setVolume(0);
              await _playReady(allowed: () => _scrub == session);
              for (final factor in [.25, .5, .75, 1.0]) {
                if (_scrub != session) break;
                await player.setVolume(session.volume * factor);
                if (factor < 1) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                }
              }
            } else {
              await player.setVolume(session.volume);
            }
          } finally {
            if (_scrub == session) {
              _scrub = null;
              await player.setVolume(session.volume);
            }
          }
        }
      }
    }();
    await session.work;
    return applied;
  }

  /// Explicit transport commands cancel any automatic resume from a record gesture.
  Future<void> cancelScrub() async {
    final session = _scrub;
    if (session == null) return;
    _scrub = null;
    try {
      await session.work;
    } catch (_) {
      // The command below still takes precedence over a failed preview.
    }
    await player.setVolume(session.volume);
  }

  Future<void> setVolume(double volume) async {
    final session = _scrub;
    if (session != null) {
      // Keep a held record silent while remembering ducking for its release.
      session.volume = volume;
    } else {
      await player.setVolume(volume);
    }
  }

  Future<void> initialize() async {
    await player.setAudioContext(const ap.AudioContext(
      android: ap.AudioContextAndroid(audioFocus: ap.AndroidAudioFocus.none),
      iOS: ap.AudioContextIOS(category: ap.AVAudioSessionCategory.playback),
    ));
    // Configure after the player so plugin defaults cannot replace music mode.
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _subscriptions.add(player.onPlayerStateChanged.listen((state) {
      // Completion has its own transition below. Do not briefly tell iOS that
      // playback ended before the queue has decided whether there is a next item.
      if (state == ap.PlayerState.paused &&
          !_loadingSource &&
          !_handlingCompletion) {
        unawaited(_endTailGuard());
      }
      if (state != ap.PlayerState.completed ||
          _onComplete == null ||
          mediaItem.value == null) {
        _publishState(state);
      }
    }));
    _subscriptions.add(player.onPlayerComplete.listen((_) async {
      final trackId = mediaItem.value?.id;
      _traceAudio('native-complete', trackId: trackId);
      if (trackId == null || _handlingCompletion) return;
      if (_onComplete == null) return;
      _handlingCompletion = true;
      _publishState(player.state);
      try {
        // iOS can suspend Dart while the next file is downloaded/prepared.
        // This bounded native task covers the silent interval between tracks.
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          await _transitionChannel.invokeMethod<void>('begin');
        }
        await _onComplete.call(trackId);
        _traceAudio('queue-complete', trackId: mediaItem.value?.id);
      } catch (error, stack) {
        _traceAudio('queue-failed', trackId: trackId, error: error);
        FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'background audio',
          context: ErrorDescription('while advancing to the next track'),
        ));
      } finally {
        try {
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            await _transitionChannel.invokeMethod<void>('end');
          }
        } finally {
          _tailGuardTrackId = null;
          _handlingCompletion = false;
          _publishState(player.state);
        }
      }
    }));
    _subscriptions.add(player.onPositionChanged.listen((position) {
      _protectTrackEnd(position);
      playbackState.add(playbackState.value.copyWith(updatePosition: position));
    }));
    _subscriptions.add(player.onDurationChanged.listen((duration) {
      final item = mediaItem.value;
      if (item != null) mediaItem.add(item.copyWith(duration: duration));
    }));
    _subscriptions.add(session.becomingNoisyEventStream.listen((_) => pause()));
    _subscriptions.add(session.interruptionEventStream.listen((event) async {
      if (event.type == AudioInterruptionType.duck) {
        if (event.begin &&
            (_scrub?.wasPlaying ?? (player.state == ap.PlayerState.playing))) {
          _ducked = true;
          await setVolume(0.2);
        } else if (!event.begin && _ducked) {
          _ducked = false;
          await setVolume(1);
        }
        return;
      }
      if (event.begin) {
        final wasPlaying =
            _scrub?.wasPlaying ?? (player.state == ap.PlayerState.playing);
        await pause();
        _resumeAfterInterruption = wasPlaying;
      } else {
        final shouldResume = _resumeAfterInterruption &&
            event.type == AudioInterruptionType.pause;
        _resumeAfterInterruption = false;
        if (shouldResume) await play();
      }
    }));
    _publishState(player.state);
  }

  void _protectTrackEnd(Duration position) {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        player.state != ap.PlayerState.playing ||
        _loadingSource ||
        _handlingCompletion ||
        _stopped) return;
    final item = mediaItem.value;
    final duration = item?.duration;
    if (item == null || duration == null || duration <= Duration.zero) return;
    final remaining = duration - position;
    if (remaining > const Duration(seconds: 5) ||
        remaining < Duration.zero ||
        _tailGuardTrackId == item.id) return;
    // Ask while audio is still active; asking only after completion is too late
    // if iOS has already suspended the Flutter isolate during the silent gap.
    _tailGuardTrackId = item.id;
    _traceAudio('tail-protected', trackId: item.id);
    unawaited(_transitionChannel.invokeMethod<void>(
        'begin', {'origin': 'track-tail'}).catchError((Object error) {
      if (_tailGuardTrackId == item.id) _tailGuardTrackId = null;
      _traceAudio('tail-protection-failed', trackId: item.id, error: error);
    }));
  }

  Future<void> _endTailGuard() async {
    if (_tailGuardTrackId == null) return;
    _tailGuardTrackId = null;
    await _transitionChannel.invokeMethod<void>('end');
  }

  void _publishState(ap.PlayerState state) {
    final transitioning = !_stopped && (_loadingSource || _handlingCompletion);
    final playing = !_stopped &&
        (transitioning ? _playWhenReady : state == ap.PlayerState.playing);
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      playing: playing,
      processingState: _stopped
          ? AudioProcessingState.idle
          : transitioning
              ? AudioProcessingState.loading
              : state == ap.PlayerState.completed
                  ? AudioProcessingState.completed
                  : state == ap.PlayerState.stopped ||
                          state == ap.PlayerState.disposed
                      ? AudioProcessingState.idle
                      : AudioProcessingState.ready,
    ));
  }

  @override
  Future<void> skipToPrevious() async {
    await cancelScrub();
    await _onSkip?.call(-1);
  }

  @override
  Future<void> skipToNext() async {
    await cancelScrub();
    await _onSkip?.call(1);
  }

  @override
  Future<void> play() async {
    _playWhenReady = true;
    _stopped = false;
    await cancelScrub();
    await _playReady();
  }

  Future<void> _playReady(
      {bool Function()? allowed, bool sourceJustLoaded = false}) async {
    if (player.source == null ||
        (player.state == ap.PlayerState.completed && !sourceJustLoaded)) {
      return;
    }
    final session = await AudioSession.instance;
    if (await session.setActive(true) && (allowed?.call() ?? true)) {
      await player.resume();
      _traceAudio('resumed', trackId: mediaItem.value?.id);
    }
  }

  /// Mount a record without spinning it when the needle is raised.
  Future<void> load(ap.Source source, {bool autoplay = true}) async {
    await cancelScrub();
    if (_handlingCompletion && _stopped) return;
    if (!_handlingCompletion) {
      await _endTailGuard();
      _playWhenReady = autoplay;
      _stopped = false;
    }
    _loadingSource = true;
    _publishState(player.state);
    try {
      // Replacing AVPlayerItem is sufficient. release() also stops/seeks the old
      // item and publishes idle, which tears down the system audio service.
      await player.pause();
      if (_stopped) return;
      _traceAudio('source-loading', trackId: mediaItem.value?.id);
      await player.setSource(source);
      _traceAudio('source-ready', trackId: mediaItem.value?.id);
      if (_stopped) return;
      if (_playWhenReady) {
        await _playReady(sourceJustLoaded: true, allowed: () => _playWhenReady);
      } else {
        await player.pause();
      }
    } finally {
      _loadingSource = false;
      _publishState(player.state);
    }
  }

  @override
  Future<void> pause() async {
    _playWhenReady = false;
    _resumeAfterInterruption = false;
    await _endTailGuard();
    await cancelScrub();
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _endTailGuard();
    final wasPlaying = _scrub?.wasPlaying ?? false;
    await cancelScrub();
    await _seekPosition(position);
    if (wasPlaying) await _playReady();
  }

  Future<void> _seekPosition(Duration position) async {
    await player.seek(position);
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  @override
  Future<void> stop() async {
    _playWhenReady = false;
    _stopped = true;
    _resumeAfterInterruption = false;
    await _endTailGuard();
    await cancelScrub();
    await player.stop();
    final session = await AudioSession.instance;
    await session.setActive(false);
    await super.stop();
  }

  Future<void> dispose() async {
    await _endTailGuard();
    await cancelScrub();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}

@Riverpod(keepAlive: true)
class PlayerStateNotifier extends _$PlayerStateNotifier {
  late AudioHandler _audioHandler;
  int _playRequest = 0;
  String? _preparingTrackId;

  @override
  PlayerState build() {
    _audioHandler = ref.watch(audioHandlerProvider).requireValue;
    final subscriptions = <StreamSubscription<dynamic>>[
      _audioHandler.player.onPlayerStateChanged.listen((value) {
        state = state.copyWith(state: value);
      }),
      _audioHandler.player.onDurationChanged.listen((value) {
        state = state.copyWith(length: value);
      }),
      _audioHandler.player.onPositionChanged.listen((value) {
        state = state.copyWith(now: value);
      }),
    ];
    ref.onDispose(() {
      _playRequest++;
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    });
    return PlayerState();
  }

  Future<void> playTrack(Track track, {bool autoplay = true}) async {
    final request = ++_playRequest;
    state = state.copyWith(loading: true);
    try {
      await _audioHandler.cancelScrub();
      _traceAudio('audio-loading', trackId: track.bvid);
      final bytes = await ref.read(trackBytesProvider(track).future);
      _traceAudio('audio-ready', trackId: track.bvid);
      if (request != _playRequest) return;

      ap.Source source = ap.BytesSource(bytes);
      if (Platform.isIOS) {
        // AVPlayer needs a file with the actual container extension (Bilibili AAC).
        final directory = await getTemporaryDirectory();
        final name = base64Url.encode(utf8.encode(track.bvid));
        final file = File(path.join(directory.path, 'listen2-$name.m4a'));
        await file.writeAsBytes(bytes, flush: true);
        source = ap.DeviceFileSource(file.path);
      }
      if (request != _playRequest) return;
      state = PlayerState(track: track, loading: true);
      _audioHandler.mediaItem.add(MediaItem(
        id: track.bvid,
        title: track.title,
        artist: track.singer,
        artUri: Uri.tryParse(track.pictureUrl),
      ));
      _audioHandler.playbackState
          .add(_audioHandler.playbackState.value.copyWith(
        updatePosition: Duration.zero,
        processingState: AudioProcessingState.loading,
      ));
      try {
        await _audioHandler.load(source, autoplay: autoplay);
        if (request == _playRequest &&
            _audioHandler.player.state == ap.PlayerState.playing) {
          unawaited(prepareNext());
        }
      } catch (_) {
        await _audioHandler.stop();
        rethrow;
      }
    } finally {
      if (request == _playRequest) state = state.copyWith(loading: false);
    }
  }

  /// Warm one queue entry while audio still keeps iOS running. Completion should
  /// not have to start metadata and audio downloads during a silent interval.
  Future<void> prepareNext() async {
    final request = _playRequest;
    final activeId = state.track?.bvid;
    if (activeId == null) return;
    final queue = ref.read(currentPlaylistNotifierProvider);
    final savedIndex = queue.index;
    final index = savedIndex >= 0 &&
            savedIndex < queue.playlist.length &&
            queue.playlist[savedIndex] == activeId
        ? savedIndex
        : queue.playlist.indexOf(activeId);
    if (index < 0 || index + 1 >= queue.playlist.length) return;
    final nextId = queue.playlist[index + 1];
    if (_preparingTrackId == nextId) return;
    _preparingTrackId = nextId;
    Track? next;
    try {
      _traceAudio('prefetch-start', trackId: nextId);
      final Track target = await ref.read(trackProvider(nextId).future);
      next = target;
      if (request != _playRequest) return;
      await ref.read(trackBytesProvider(target).future);
      _traceAudio('prefetch-ready', trackId: nextId);
    } catch (error) {
      // A speculative download must not stop the current song. A real play
      // request will retry and surface its own failure if still unavailable.
      _traceAudio('prefetch-failed', trackId: nextId, error: error);
      if (request == _playRequest) {
        // Remove a failed speculative future so a later real play can retry,
        // even when Flutter has no background frame to auto-dispose it.
        if (next == null) {
          ref.invalidate(trackProvider(nextId));
        } else {
          ref.invalidate(trackBytesProvider(next));
        }
      }
    } finally {
      if (_preparingTrackId == nextId) _preparingTrackId = null;
    }
  }

  Future<void> playTrackById(String trackId, {bool autoplay = true}) async {
    if (trackId.isEmpty) {
      _playRequest++;
      await _audioHandler.stop();
      _audioHandler.mediaItem.add(null);
      state = PlayerState();
      return;
    }
    _traceAudio('metadata-loading', trackId: trackId);
    final track = await ref.read(trackProvider(trackId).future);
    _traceAudio('metadata-ready', trackId: trackId);
    await playTrack(track, autoplay: autoplay);
  }

  Future<void> pause() => _audioHandler.pause();
  Future<void> resume() => _audioHandler.play();
  Future<void> beginScrub() => _audioHandler.beginScrub();
  Future<void> cancelScrub() => _audioHandler.cancelScrub();
  Future<void> finishScrub([Duration? target]) async {
    final request = _playRequest;
    if (await _audioHandler.finishScrub(target) &&
        target != null &&
        request == _playRequest) {
      state = state.copyWith(now: target);
    }
  }

  Future<void> seek(Duration position) async {
    await _audioHandler.seek(position);
    state = state.copyWith(now: position);
  }
}

@Riverpod(keepAlive: true)
Future<AudioHandler> audioHandler(AudioHandlerRef ref) async {
  final handler = await AudioService.init(
    builder: () => AudioHandler(
      onSkip: (direction) async {
        await ref
            .read(currentPlaylistNotifierProvider.notifier)
            .skip(direction);
      },
      onComplete: (trackId) async {
        await ref
            .read(currentPlaylistNotifierProvider.notifier)
            .onTrackCompleted(trackId);
      },
    ),
    config: const AudioServiceConfig(androidStopForegroundOnPause: false),
  );
  await handler.initialize();
  ref.onDispose(() => handler.dispose());
  return handler;
}
