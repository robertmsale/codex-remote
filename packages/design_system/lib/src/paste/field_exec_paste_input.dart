import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_paste_input/flutter_paste_input.dart';

class FieldExecPasteService {
  FieldExecPasteService._();

  static final FieldExecPasteService instance = FieldExecPasteService._();

  bool _initialized = false;
  StreamSubscription<PastePayload>? _sub;
  TextEditingController? _activeController;

  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isMacOS) return;

    PasteChannel.instance.initialize();
    _sub = PasteChannel.instance.onPaste.listen(_onPaste);
  }

  void setActive(TextEditingController controller) {
    _activeController = controller;
  }

  void clearActive(TextEditingController controller) {
    if (_activeController == controller) {
      _activeController = null;
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _activeController = null;
    _initialized = false;
  }

  void _onPaste(PastePayload payload) {
    if (payload is! TextPaste) return;
    final text = payload.text;
    if (text.isEmpty) return;

    // Wispr Flow uses Cmd+Ctrl+V. Only intercept when that modifier combo is
    // currently held to avoid double-inserting on normal Cmd+V.
    if (!_isCmdCtrlHeld()) return;

    final controller = _activeController;
    if (controller == null) return;

    try {
      _insertText(controller, text);
    } catch (_) {
      // If the controller is disposed or otherwise invalid, ignore.
    }
  }

  bool _isCmdCtrlHeld() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;

    final hasCmd =
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.meta);

    final hasCtrl =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.control);

    return hasCmd && hasCtrl;
  }

  void _insertText(TextEditingController controller, String insert) {
    final value = controller.value;
    final selection = value.selection;

    final int start = selection.start >= 0
        ? selection.start
        : value.text.length;
    final int end = selection.end >= 0 ? selection.end : value.text.length;

    final newText = value.text.replaceRange(start, end, insert);
    controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insert.length),
      composing: TextRange.empty,
    );
  }
}

class FieldExecPasteTarget extends StatefulWidget {
  const FieldExecPasteTarget({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  final TextEditingController controller;
  final Widget child;
  final bool enabled;

  @override
  State<FieldExecPasteTarget> createState() => _FieldExecPasteTargetState();
}

class _FieldExecPasteTargetState extends State<FieldExecPasteTarget> {
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      FieldExecPasteService.instance.ensureInitialized();
    }
  }

  @override
  void didUpdateWidget(covariant FieldExecPasteTarget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        FieldExecPasteService.instance.ensureInitialized();
        if (_hasFocus) {
          FieldExecPasteService.instance.setActive(widget.controller);
        }
      } else {
        if (_hasFocus) {
          FieldExecPasteService.instance.clearActive(oldWidget.controller);
        }
      }
      return;
    }

    if (!widget.enabled) return;

    if (oldWidget.controller != widget.controller) {
      if (_hasFocus) {
        FieldExecPasteService.instance.clearActive(oldWidget.controller);
        FieldExecPasteService.instance.setActive(widget.controller);
      }
    }
  }

  void _onFocusChanged(bool hasFocus) {
    if (!widget.enabled) return;
    _hasFocus = hasFocus;
    if (hasFocus) {
      FieldExecPasteService.instance.setActive(widget.controller);
    } else {
      FieldExecPasteService.instance.clearActive(widget.controller);
    }
  }

  @override
  void dispose() {
    if (widget.enabled && _hasFocus) {
      FieldExecPasteService.instance.clearActive(widget.controller);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !Platform.isMacOS) {
      return widget.child;
    }

    return Focus(onFocusChange: _onFocusChanged, child: widget.child);
  }
}
