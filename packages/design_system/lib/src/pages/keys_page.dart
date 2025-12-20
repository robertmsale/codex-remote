import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/keys_controller_base.dart';
import '../paste/field_exec_paste_input.dart';
import 'install_key_page.dart';

class KeysPage extends GetView<KeysControllerBase> {
  const KeysPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SSH Keys')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (Platform.isMacOS || Platform.isLinux) ...[
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Use Key From ~/.ssh',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Obx(
                    () => IconButton(
                      tooltip: 'Rescan',
                      onPressed:
                          (controller.busy.value ||
                              controller.scanningLocalKeys.value)
                          ? null
                          : controller.scanLocalKeys,
                      icon: controller.scanningLocalKeys.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Pick an existing SSH private key. Passphrase-protected keys may not work yet.',
              ),
              const SizedBox(height: 8),
              Obx(() {
                final items = controller.localKeyCandidates;
                if (controller.scanningLocalKeys.value) {
                  return const SizedBox.shrink();
                }
                if (items.isEmpty) {
                  return const Text('No SSH private keys found in ~/.ssh.');
                }
                return Column(
                  children: [
                    for (final k in items)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          k.looksEncrypted ? Icons.lock : Icons.key,
                        ),
                        title: Text(k.filename),
                        subtitle: Text(k.path),
                        trailing: FilledButton(
                          onPressed: controller.busy.value
                              ? null
                              : () async {
                                  controller.busy.value = true;
                                  try {
                                    await controller.useLocalKey(k);
                                  } finally {
                                    controller.busy.value = false;
                                  }
                                },
                          child: const Text('Use'),
                        ),
                      ),
                    const Divider(),
                  ],
                );
              }),
              const SizedBox(height: 12),
            ],
            const Text(
              'Global Private Key (PEM)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            FieldExecPasteTarget(
              controller: controller.pemController,
              child: TextField(
                controller: controller.pemController,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: 'Paste an OpenSSH private key PEM here',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: controller.busy.value
                          ? null
                          : () async {
                              controller.busy.value = true;
                              try {
                                await controller.save();
                              } finally {
                                controller.busy.value = false;
                              }
                            },
                      child: const Text('Save'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: controller.busy.value
                          ? null
                          : () async {
                              controller.busy.value = true;
                              try {
                                await controller.deleteKey();
                              } finally {
                                controller.busy.value = false;
                              }
                            },
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: controller.busy.value
                          ? null
                          : () async {
                              controller.busy.value = true;
                              try {
                                await controller.generate();
                              } finally {
                                controller.busy.value = false;
                              }
                            },
                      child: const Text('Generate New Key'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: controller.busy.value
                          ? null
                          : () async {
                              controller.busy.value = true;
                              try {
                                await controller.copyPublicKey();
                              } finally {
                                controller.busy.value = false;
                              }
                            },
                      child: const Text('Copy Public Key'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Obx(() => Text(controller.status.value)),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Install key on server'),
              subtitle: const Text('Password-based setup, then key auth'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Get.to(() => const InstallKeyPage()),
            ),
          ],
        ),
      ),
    );
  }
}
