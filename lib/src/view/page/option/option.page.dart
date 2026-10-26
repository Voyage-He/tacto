import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:listen2/src/widget/app_style.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:listen2/src/playlist_backup.dart';
import 'package:listen2/src/provider/repo/playlist_tracks_id.dart';
import 'package:listen2/src/provider/global/background_settings.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/widget/app_version.dart';
import 'package:listen2/src/widget/player_background.dart';
import 'package:listen2/src/view/page/option/bilibili_account.page.dart';

class Option extends ConsumerStatefulWidget {
  const Option({super.key});

  @override
  ConsumerState<Option> createState() => _OptionState();
}

class _OptionState extends ConsumerState<Option> {
  bool _busy = false;
  String? _message;
  String? _backgroundError;
  bool _savingPlayback = false;
  String? _playbackError;
  Future<void> _setAutoplay(bool enabled) async {
    if (_savingPlayback) return;
    setState(() {
      _savingPlayback = true;
      _playbackError = null;
    });
    try {
      await ref.read(autoplayOnStartupProvider.notifier).setAutoplay(enabled);
    } catch (_) {
      if (mounted) setState(() => _playbackError = '播放设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingPlayback = false);
    }
  }

  Future<void> _saveBackground() async {
    try {
      await ref.read(backgroundSettingsProvider.notifier).save();
      if (mounted && _backgroundError != null) {
        setState(() => _backgroundError = null);
      }
    } catch (_) {
      if (mounted) setState(() => _backgroundError = '背景设置保存失败，请重试');
    }
  }

  Future<void> _run(Future<String?> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await operation();
      if (mounted) setState(() => _message = message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = '备份操作失败，请检查文件后重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _exportBackup() async {
    final bytes = PlaylistBackup.encode(
        ref.read(playlistIdsNotifierProvider('favorite')));
    // On iOS/Android the native document picker writes these bytes itself.
    final path = await FilePicker.platform.saveFile(
      fileName: 'listen2.back',
      bytes: bytes,
    );
    if (path == null) return null;
    if (!Platform.isIOS && !Platform.isAndroid) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return '收藏备份已导出';
  }

  Future<String?> _importBackup() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final favorites = PlaylistBackup.decode(bytes);
    if (!mounted) return null;
    ref.read(playlistIdsNotifierProvider('favorite').notifier).set(favorites);
    return '收藏备份已导入';
  }

  @override
  Widget build(BuildContext context) {
    final background = ref.watch(backgroundSettingsProvider);
    final autoplay = ref.watch(autoplayOnStartupProvider);
    return PageSurface(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading('设置'),
        Expanded(
            child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
              _backupTile(
                  Icons.account_circle_outlined,
                  'Bilibili 账号与收藏夹',
                  '扫码登录，访问私密收藏夹并管理收藏',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const BilibiliAccountPage()))),
              const SizedBox(height: 28),
              Text('播放', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  child: SwitchListTile(
                      key: const ValueKey('autoplay-on-startup-switch'),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      title: const Text('打开应用时自动播放',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('下次打开应用时生效，关闭后恢复歌曲但保持暂停'),
                      value: autoplay,
                      onChanged: _savingPlayback ? null : _setAutoplay)),
              if (_playbackError != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_playbackError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 28),
              Text('背景外观', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('调节歌曲封面的背景效果，修改即时生效。',
                  style: TextStyle(color: AppStyle.muted, fontSize: 14)),
              const SizedBox(height: 16),
              ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: const SizedBox(
                      height: 108,
                      child: ColoredBox(
                          color: AppStyle.background,
                          child: Stack(fit: StackFit.expand, children: [
                            PlayerBackground(),
                            Center(
                                child: Text('背景预览',
                                    style: TextStyle(color: AppStyle.ink))),
                          ])))),
              const SizedBox(height: 16),
              _backgroundSlider(
                  key: 'background-blur-slider',
                  title: '背景虚化',
                  hint: '越大，封面轮廓越柔和',
                  value: background.blur,
                  max: BackgroundSettings.maxBlur,
                  divisions: 64,
                  onChanged:
                      ref.read(backgroundSettingsProvider.notifier).setBlur),
              const SizedBox(height: 12),
              _backgroundSlider(
                  key: 'background-gradient-slider',
                  title: '渐变强度',
                  hint: '越大，封面向浅色背景过渡越明显',
                  value: background.gradient,
                  max: 1,
                  divisions: 100,
                  onChanged: ref
                      .read(backgroundSettingsProvider.notifier)
                      .setGradient),
              if (_backgroundError != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_backgroundError!,
                        style: const TextStyle(color: AppStyle.muted))),
              const SizedBox(height: 28),
              Text('音乐与备份', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('保存你的收藏，换设备也能继续聆听。',
                  style: TextStyle(color: AppStyle.muted, fontSize: 14)),
              const SizedBox(height: 24),
              _backupTile(Icons.upload_rounded, '导出收藏备份', '将我喜欢的音乐保存到文件',
                  () => _run(_exportBackup)),
              const SizedBox(height: 12),
              _backupTile(Icons.download_rounded, '导入收藏备份', '用备份文件替换当前收藏',
                  () => _run(_importBackup)),
              if (_busy)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator())),
              if (_message != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(_message!,
                        style: Theme.of(context).textTheme.bodyLarge)),
              const AppVersionFooter(),
            ])),
      ],
    ));
  }

  Widget _backgroundSlider(
      {required String key,
      required String title,
      required String hint,
      required double value,
      required double max,
      required int divisions,
      required ValueChanged<double> onChanged}) {
    final percent = (value / max * 100).round();
    return Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium)),
                Text('$percent%',
                    style: const TextStyle(color: AppStyle.accent)),
              ]),
              Slider(
                  key: ValueKey(key),
                  value: value,
                  max: max,
                  divisions: divisions,
                  label: '$percent%',
                  semanticFormatterCallback: (value) =>
                      '$title ${(value / max * 100).round()}%',
                  onChanged: onChanged,
                  onChangeEnd: (_) => _saveBackground()),
              Text(hint,
                  style: const TextStyle(color: AppStyle.muted, fontSize: 12)),
            ])));
  }

  Widget _backupTile(
          IconData icon, String title, String subtitle, VoidCallback onTap) =>
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
            enabled: !_busy,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            leading: Icon(icon, color: AppStyle.accent),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onTap),
      );
}
