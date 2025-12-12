class ActiveSessionRef {
  final String targetKey;
  final String projectPath;
  final String tabId;

  const ActiveSessionRef({
    required this.targetKey,
    required this.projectPath,
    required this.tabId,
  });
}

class ActiveSessionService {
  ActiveSessionRef? _active;

  ActiveSessionRef? get active => _active;

  void setActive(ActiveSessionRef? ref) {
    _active = ref;
  }
}

