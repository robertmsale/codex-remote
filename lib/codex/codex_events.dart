class CodexStructuredAction {
  final String id;
  final String label;
  final String value;

  const CodexStructuredAction({
    required this.id,
    required this.label,
    required this.value,
  });

  factory CodexStructuredAction.fromJson(Map<String, Object?> json) {
    return CodexStructuredAction(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      value: (json['value'] as String?) ?? '',
    );
  }
}

class CodexStructuredImageRef {
  final String path;
  final String caption;

  const CodexStructuredImageRef({required this.path, required this.caption});

  factory CodexStructuredImageRef.fromJson(Map<String, Object?> json) {
    return CodexStructuredImageRef(
      path: json['path']?.toString() ?? '',
      caption: json['caption']?.toString() ?? '',
    );
  }
}

class CodexStructuredResponse {
  final String message;
  final String commitMessage;
  final List<CodexStructuredImageRef> images;
  final List<CodexStructuredAction> actions;

  const CodexStructuredResponse({
    required this.message,
    required this.commitMessage,
    required this.images,
    required this.actions,
  });

  factory CodexStructuredResponse.fromJson(Map<String, Object?> json) {
    final imagesRaw = (json['images'] as List?) ?? const [];
    final images = imagesRaw
        .whereType<Map>()
        .map((m) => CodexStructuredImageRef.fromJson(m.cast<String, Object?>()))
        .where((i) => i.path.trim().isNotEmpty)
        .toList(growable: false);
    final actionsRaw = (json['actions'] as List?) ?? const [];
    final actions = actionsRaw
        .whereType<Map>()
        .map((m) => CodexStructuredAction.fromJson(m.cast<String, Object?>()))
        .where((a) => a.id.isNotEmpty && a.label.isNotEmpty && a.value.isNotEmpty)
        .toList(growable: false);
    return CodexStructuredResponse(
      message: (json['message'] as String?) ?? '',
      commitMessage: (json['commit_message'] as String?) ?? '',
      images: images,
      actions: actions,
    );
  }
}
