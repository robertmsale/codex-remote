import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:design_system/design_system.dart';

class DesktopProjectWindowLauncher implements ProjectWindowLauncher {
  @override
  bool get enabled => Platform.isMacOS || Platform.isLinux;

  @override
  Future<void> openProject(ProjectArgs args) async {
    if (!enabled) return;

    final payload = jsonEncode(<String, Object?>{
      'type': 'open_project',
      'project': args.project.toJson(),
      'target':
          args.target.local
              ? <String, Object?>{'local': true}
              : <String, Object?>{
                'local': false,
                'profile': args.target.profile?.toJson(),
              },
    });

    final controller = await WindowController.create(
      WindowConfiguration(arguments: payload, hiddenAtLaunch: true),
    );
    await controller.show();
  }
}

