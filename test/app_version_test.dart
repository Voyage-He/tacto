import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listen2/src/widget/app_version.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('version label keeps the name and adds a distinct build', () {
    expect(formatAppVersion('0.9.6', '0.9.6'), '0.9.6');
    expect(formatAppVersion('0.9.6', ''), '0.9.6');
    expect(formatAppVersion(' 0.9.7 ', '12'), '0.9.7 (12)');
    expect(formatAppVersion('  ', '4'), '4');
  });

  testWidgets('footer shows the installed app version', (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Tacto',
        packageName: 'com.example.listen2',
        version: '0.9.6',
        buildNumber: '0.9.6',
        buildSignature: '');
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AppVersionFooter())));
    await tester.pumpAndSettle();
    expect(find.text('Tacto'), findsOneWidget);
    expect(find.text('版本 0.9.6'), findsOneWidget);
  });
}
