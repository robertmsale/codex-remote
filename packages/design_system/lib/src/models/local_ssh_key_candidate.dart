class LocalSshKeyCandidate {
  final String path;
  final bool looksEncrypted;

  const LocalSshKeyCandidate({
    required this.path,
    required this.looksEncrypted,
  });

  String get filename {
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }
}
