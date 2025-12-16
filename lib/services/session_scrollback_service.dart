import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionScrollbackService {
  static const _key = 'field_exec_session_scrollback_lines_v1';
  static const int defaultLines = 400;

  final linesRx = defaultLines.obs;

  int get lines => linesRx.value;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getInt(_key);
    linesRx.value = clampLines(raw ?? defaultLines);
  }

  Future<void> setLines(int lines) async {
    final next = clampLines(lines);
    linesRx.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, next);
  }

  static int clampLines(int v) => v.clamp(200, 20000);
}
