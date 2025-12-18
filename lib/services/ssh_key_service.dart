import 'dart:io';

import '../rinf/rust_ssh_service.dart';
import 'field_execd_client.dart';

class SshKeyService {
  static const defaultComment = 'field-exec';

  final FieldExecdClient? _daemon;

  SshKeyService({FieldExecdClient? daemon}) : _daemon = daemon;

  Future<String> generateEd25519PrivateKeyPem({String comment = defaultComment}) async {
    final daemon = _daemon;
    if (daemon != null && (Platform.isMacOS || Platform.isLinux)) {
      final res = await daemon.request(
        method: 'ssh.generate_key',
        params: <String, Object?>{'comment': comment},
      );
      return (res['private_key_pem'] as String?) ?? '';
    }
    return RustSshService.generateEd25519PrivateKeyPem(comment: comment);
  }

  Future<String> toAuthorizedKeysLine({
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = defaultComment,
  }) async {
    final daemon = _daemon;
    if (daemon != null && (Platform.isMacOS || Platform.isLinux)) {
      final res = await daemon.request(
        method: 'ssh.authorized_key_line',
        params: <String, Object?>{
          'private_key_pem': privateKeyPem,
          'private_key_passphrase': privateKeyPassphrase,
          'comment': comment,
        },
      );
      return (res['authorized_key_line'] as String?) ?? '';
    }
    return RustSshService.toAuthorizedKeysLine(
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      comment: comment,
    );
  }
}
