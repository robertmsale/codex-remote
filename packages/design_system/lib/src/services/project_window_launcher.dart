import '../args/project_args.dart';

abstract class ProjectWindowLauncher {
  bool get enabled;

  Future<void> openProject(ProjectArgs args);
}

