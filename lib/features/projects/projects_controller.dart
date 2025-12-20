import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../services/project_store.dart';
import '../../services/shared_projects_service.dart';

class ProjectsController extends ProjectsControllerBase {
  @override
  final TargetArgs target;

  ProjectsController({required this.target});

  @override
  final projects = <Project>[].obs;
  @override
  final isBusy = false.obs;
  @override
  final status = ''.obs;

  final _uuid = const Uuid();

  ProjectStore get _store => Get.find<ProjectStore>();
  SharedProjectsService get _shared => Get.find<SharedProjectsService>();
  SharedProjectsWatchHandle? _watch;
  Future<void> _loadQueue = Future.value();

  static int _compareProjects(Project a, Project b) {
    final an = a.name.trim().toLowerCase();
    final bn = b.name.trim().toLowerCase();
    final c = an.compareTo(bn);
    if (c != 0) return c;
    return a.path.trim().toLowerCase().compareTo(b.path.trim().toLowerCase());
  }

  @override
  void onInit() {
    super.onInit();
    _load();
    _watch = _shared.watchProjects(
      target: target,
      onChanged: () {
        _loadQueue = _loadQueue.then((_) async {
          await _load();
        });
      },
    );
  }

  @override
  void onClose() {
    try {
      _watch?.cancel();
    } catch (_) {}
    _watch = null;
    super.onClose();
  }

  Future<void> _load() async {
    isBusy.value = true;
    try {
      final loaded = await _shared.loadProjects(target: target);
      final next = loaded.toList(growable: true)..sort(_compareProjects);
      projects.assignAll(next);
    } finally {
      isBusy.value = false;
    }
  }

  @override
  Future<Project?> promptAddProject() async {
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    try {
      final result = await Get.dialog<Project>(
        AlertDialog(
          title: const Text('Add project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FieldExecPasteTarget(
                controller: pathController,
                child: TextField(
                  controller: pathController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Path',
                    hintText: '/Users/me/repo or /home/me/repo',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FieldExecPasteTarget(
                controller: nameController,
                child: TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name (optional)',
                    hintText: 'my-repo',
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final path = pathController.text.trim();
                if (path.isEmpty) return;
                final name = nameController.text.trim();
                final fallback = path
                    .split('/')
                    .where((p) => p.isNotEmpty)
                    .last;
                Get.back(
                  result: Project(
                    id: _uuid.v4(),
                    path: path,
                    name: name.isEmpty ? fallback : name,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      );
      return result;
    } finally {
      pathController.dispose();
      nameController.dispose();
    }
  }

  @override
  Future<void> addProject(Project project) async {
    final next = [project, ...projects].toList(growable: true)
      ..sort(_compareProjects);
    final capped = next.take(25).toList(growable: false);
    projects.assignAll(capped);
    await _shared.saveProjects(target: target, projects: capped);
    await _store.saveLastProjectId(
      targetKey: target.targetKey,
      projectId: project.id,
    );
  }

  @override
  Future<void> updateProject(Project project) async {
    final idx = projects.indexWhere((p) => p.id == project.id);
    if (idx == -1) return;
    final next = projects.toList(growable: true);
    next[idx] = project;
    next.sort(_compareProjects);
    projects.assignAll(next);
    await _shared.saveProjects(
      target: target,
      projects: next.toList(growable: false),
    );
  }

  @override
  Future<void> deleteProject(Project project) async {
    final next = projects
        .where((p) => p.id != project.id)
        .toList(growable: true)
      ..sort(_compareProjects);
    projects.assignAll(next);
    await _shared.saveProjects(
      target: target,
      projects: next.toList(growable: false),
    );
  }
}
