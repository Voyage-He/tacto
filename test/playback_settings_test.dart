import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:listen2/src/provider/global/playback_settings.dart';
import 'package:listen2/src/provider/global/player.dart';
import 'package:listen2/src/provider/global/storage.dart';
import 'package:listen2/src/view/page/option/option.page.dart';
import 'package:listen2/src/widget/app_style.dart';

class _IdlePlayer extends PlayerStateNotifier {
  @override
  PlayerState build() => PlayerState();
}

class _SavingSettings extends PlaybackSettingsNotifier {
  final changes = <bool>[];
  Completer<void>? pending;
  bool fail = false;

  @override
  bool build() => true;

  @override
  Future<void> setAutoplay(bool enabled) async {
    changes.add(enabled);
    await pending?.future;
    if (fail) throw StateError('storage unavailable');
    state = enabled;
  }
}

void main() {
  late Directory directory;
  late Storage storage;
  late ProviderContainer container;

  Future<Storage> openStorage() async {
    final setting = await Hive.openBox('setting');
    return Storage(
        setting, setting, await Hive.openBox<Uint8List>('binary'), {});
  }

  ProviderContainer createContainer({_SavingSettings? settings}) =>
      ProviderContainer(overrides: [
        hiveStorageProvider.overrideWith((ref) async => storage),
        playerStateNotifierProvider.overrideWith(_IdlePlayer.new),
        if (settings != null)
          autoplayOnStartupProvider.overrideWith(() => settings),
      ]);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listen2-playback-test-');
    Hive.init(directory.path);
    storage = await openStorage();
    container = createContainer();
    await container.read(hiveStorageProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('autoplay defaults on and disabled preference survives a disk reopen',
      () async {
    expect(container.read(autoplayOnStartupProvider), isTrue);
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(false);
    container.dispose();
    await Hive.close();
    storage = await openStorage();
    container = createContainer();
    await container.read(hiveStorageProvider.future);
    expect(container.read(autoplayOnStartupProvider), isFalse);
    await container.read(autoplayOnStartupProvider.notifier).setAutoplay(true);
    expect(storage.setting.get('autoplayOnStartup'), isTrue);
  });

  test('invalid saved values use the default and failed saves keep the value',
      () async {
    await storage.setting.put('autoplayOnStartup', 'false');
    expect(container.read(autoplayOnStartupProvider), isTrue);
    final settings = container.read(autoplayOnStartupProvider.notifier);
    await storage.setting.close();
    await expectLater(settings.setAutoplay(false), throwsA(isA<HiveError>()));
    expect(container.read(autoplayOnStartupProvider), isTrue);
  });

  testWidgets('settings switch saves changes and shows failed saves',
      (tester) async {
    final settings = _SavingSettings()..pending = Completer<void>();
    container.dispose();
    container = createContainer(settings: settings);
    await container.read(hiveStorageProvider.future);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: AppStyle.theme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!),
            home: const Scaffold(body: Option()))));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('autoplay-on-startup-switch'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    await tester.tap(toggle);
    expect(settings.changes, [false]);
    settings.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    settings.pending = null;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    settings.fail = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('播放设置保存失败，请重试'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
