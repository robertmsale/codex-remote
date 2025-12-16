import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/settings_controller_base.dart';
import 'keys_page.dart';

class SettingsPage extends GetView<SettingsControllerBase> {
  const SettingsPage({super.key});

  static String _labelFor(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  static String _scrollbackLabel(int lines) => '$lines lines';

  Future<void> _pickScrollbackLines(BuildContext context) async {
    const presets = <int>[200, 400, 800, 1600, 4000, 8000, 20000];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Obx(() {
            final current = controller.sessionScrollbackLines.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'Session scrollback',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'How many JSONL log lines are loaded on open/refresh.',
                  ),
                ),
                for (final v in presets)
                  ListTile(
                    title: Text(_scrollbackLabel(v)),
                    trailing: current == v ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.of(context).pop(v),
                  ),
                const SizedBox(height: 8),
              ],
            );
          }),
        );
      },
    );

    if (picked == null) return;
    await controller.setSessionScrollbackLines(picked);
  }

  Future<void> _pickThemeMode(BuildContext context) async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Obx(() {
            final current = controller.themeMode.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'Theme',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                ListTile(
                  title: const Text('System'),
                  subtitle: const Text('Follow device setting (default)'),
                  trailing: current == ThemeMode.system
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(ThemeMode.system),
                ),
                ListTile(
                  title: const Text('Light'),
                  trailing: current == ThemeMode.light
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(ThemeMode.light),
                ),
                ListTile(
                  title: const Text('Dark'),
                  trailing: current == ThemeMode.dark
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(ThemeMode.dark),
                ),
                const SizedBox(height: 8),
              ],
            );
          }),
        );
      },
    );

    if (picked == null) return;
    await controller.setThemeMode(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 16, top: 12, bottom: 4),
            child: Text(
              'Appearance',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Obx(
            () => ListTile(
              title: const Text('Theme'),
              subtitle: Text(_labelFor(controller.themeMode.value)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickThemeMode(context),
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.only(left: 16, top: 12, bottom: 4),
            child: Text(
              'Sessions',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Obx(
            () => ListTile(
              title: const Text('Scrollback'),
              subtitle: Text(_scrollbackLabel(controller.sessionScrollbackLines.value)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickScrollbackLines(context),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            title: const Text('SSH Keys'),
            subtitle: const Text('Manage the global key used for connections'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Get.to(() => const KeysPage()),
          ),
        ],
      ),
    );
  }
}
