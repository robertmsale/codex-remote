import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_key_service.dart';

class KeysController extends KeysControllerBase {
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshKeyService get _keys => Get.find<SshKeyService>();

  @override
  final pemController = TextEditingController();

  @override
  final busy = false.obs;

  @override
  final status = ''.obs;

  @override
  final scanningLocalKeys = false.obs;

  @override
  final localKeyCandidates = <LocalSshKeyCandidate>[].obs;

  @override
  void onInit() {
    super.onInit();
    load();
    unawaited(scanLocalKeys());
  }

  @override
  void onClose() {
    pemController.dispose();
    super.onClose();
  }

  @override
  Future<void> load() async {
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    pemController.text = pem ?? '';
    status.value = pem == null || pem.isEmpty ? 'No key saved.' : 'Key loaded.';
  }

  @override
  Future<void> save() async {
    final pem = pemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'PEM is empty.';
      return;
    }
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: pem,
    );
    status.value = 'Saved.';
  }

  @override
  Future<void> deleteKey() async {
    await _storage.delete(key: SecureStorageService.sshPrivateKeyPemKey);
    pemController.text = '';
    status.value = 'Deleted.';
  }

  @override
  Future<void> generate() async {
    status.value = 'Generating...';
    final pem = await _keys.generateEd25519PrivateKeyPem();
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: pem,
    );
    pemController.text = pem;
    status.value = 'Generated and saved.';
  }

  @override
  Future<void> copyPublicKey() async {
    final pem = pemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'No private key to derive public key from.';
      return;
    }
    final line = await _keys.toAuthorizedKeysLine(privateKeyPem: pem);
    await Clipboard.setData(ClipboardData(text: line));
    status.value = 'Copied public key to clipboard.';
  }

  static bool _supportsLocalKeyScan() => Platform.isMacOS || Platform.isLinux;

  static String _homeDir() {
    final env = Platform.environment;
    final home = env['HOME']?.trim();
    if (home != null && home.isNotEmpty) return home;
    if (Platform.isWindows) return '';
    return '';
  }

  static bool _looksLikePrivateKeyHeader(String text) {
    return text.contains('BEGIN OPENSSH PRIVATE KEY') ||
        text.contains('BEGIN RSA PRIVATE KEY') ||
        text.contains('BEGIN EC PRIVATE KEY') ||
        text.contains('BEGIN DSA PRIVATE KEY');
  }

  static bool _looksEncrypted(String text) {
    final upper = text.toUpperCase();
    if (upper.contains('ENCRYPTED')) return true;
    // Heuristic: OpenSSH new-format keys often mention cipher/kdf hints when encrypted.
    if (text.contains('bcrypt')) return true;
    if (upper.contains('AES')) return true;
    return false;
  }

  @override
  Future<void> scanLocalKeys() async {
    if (!_supportsLocalKeyScan()) {
      localKeyCandidates.assignAll(const []);
      return;
    }
    if (scanningLocalKeys.value) return;
    scanningLocalKeys.value = true;
    try {
      final home = _homeDir();
      if (home.isEmpty) {
        localKeyCandidates.assignAll(const []);
        status.value = 'Unable to locate HOME directory for ~/.ssh.';
        return;
      }
      final dir = Directory('$home/.ssh');
      if (!await dir.exists()) {
        localKeyCandidates.assignAll(const []);
        status.value = 'No ~/.ssh folder found.';
        return;
      }

      final entries = await dir.list(followLinks: false).toList();
      final candidates = <LocalSshKeyCandidate>[];
      for (final e in entries) {
        if (e is! File) continue;
        final path = e.path;
        final name = path.split('/').last;
        if (name.isEmpty) continue;
        if (name.endsWith('.pub')) continue;
        if (name == 'known_hosts' ||
            name.startsWith('known_hosts.') ||
            name == 'authorized_keys' ||
            name.startsWith('authorized_keys.') ||
            name == 'config') {
          continue;
        }
        // Only include files that look like SSH private keys.
        try {
          final bytes = await e
              .openRead(0, 4096)
              .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
          final head = utf8.decode(bytes, allowMalformed: true);
          if (!_looksLikePrivateKeyHeader(head)) continue;
          candidates.add(
            LocalSshKeyCandidate(
              path: path,
              looksEncrypted: _looksEncrypted(head),
            ),
          );
        } catch (_) {
          // Ignore unreadable files.
        }
      }

      int rank(LocalSshKeyCandidate c) {
        switch (c.filename) {
          case 'id_ed25519':
            return 0;
          case 'id_rsa':
            return 1;
          case 'id_ecdsa':
            return 2;
          case 'id_dsa':
            return 3;
          default:
            return 10;
        }
      }

      candidates.sort((a, b) {
        final ra = rank(a);
        final rb = rank(b);
        if (ra != rb) return ra.compareTo(rb);
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });

      localKeyCandidates.assignAll(candidates);
      if (candidates.isEmpty) {
        status.value = 'No private keys found in ~/.ssh.';
      }
    } finally {
      scanningLocalKeys.value = false;
    }
  }

  @override
  Future<void> useLocalKey(LocalSshKeyCandidate key) async {
    if (!_supportsLocalKeyScan()) return;
    final file = File(key.path);
    if (!await file.exists()) {
      status.value = 'Key not found: ${key.path}';
      return;
    }
    try {
      final contents = (await file.readAsString()).trim();
      if (contents.isEmpty) {
        status.value = 'Key file is empty: ${key.path}';
        return;
      }
      await _storage.write(
        key: SecureStorageService.sshPrivateKeyPemKey,
        value: contents,
      );
      pemController.text = contents;
      status.value = key.looksEncrypted
          ? 'Imported key (may be passphrase-protected).'
          : 'Imported key from ~/.ssh.';
    } catch (e) {
      status.value = 'Failed to import key: $e';
    }
  }
}
