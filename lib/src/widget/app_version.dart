import 'package:flutter/material.dart';
import 'package:listen2/src/widget/app_style.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Version shown in settings. A build number that only repeats the name is
/// omitted; iOS does that when pubspec has no explicit build.
String formatAppVersion(String version, String buildNumber) {
  final name = version.trim();
  final build = buildNumber.trim();
  if (name.isEmpty) return build;
  if (build.isEmpty || build == name) return name;
  return '$name ($build)';
}

class AppVersionFooter extends StatefulWidget {
  const AppVersionFooter({super.key});

  @override
  State<AppVersionFooter> createState() => _AppVersionFooterState();
}

class _AppVersionFooterState extends State<AppVersionFooter> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final label = data == null
            ? null
            : formatAppVersion(data.version, data.buildNumber);
        return Padding(
            padding: const EdgeInsets.only(top: 40, bottom: 12),
            child: Column(children: [
              const Text('Tacto',
                  style: TextStyle(
                      color: AppStyle.muted,
                      fontSize: 12,
                      letterSpacing: 2.4,
                      fontWeight: FontWeight.w600)),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('版本 $label',
                    key: const ValueKey('app-version'),
                    style:
                        const TextStyle(color: AppStyle.muted, fontSize: 13)),
              ],
            ]));
      });
}
