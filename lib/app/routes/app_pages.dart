import 'package:get/get.dart';
import 'package:design_system/design_system.dart';

import '../../features/projects/projects_controller.dart';
import '../../features/projects/project_sessions_controller.dart';
import '../../services/startup_project_args_service.dart';

abstract final class AppPages {
  static final pages = <GetPage<dynamic>>[
    GetPage(name: DesignRoutes.connect, page: ConnectionPage.new),
    GetPage(
      name: DesignRoutes.projects,
      page: ProjectsPage.new,
      binding: BindingsBuilder(() {
        final args = (Get.arguments is TargetArgs)
            ? (Get.arguments as TargetArgs)
            : const TargetArgs.local();
        Get.put<ProjectsControllerBase>(ProjectsController(target: args));
      }),
    ),
    GetPage(
      name: DesignRoutes.project,
      page: ProjectSessionsPage.new,
      binding: BindingsBuilder(() {
        final raw = Get.arguments;
        final args =
            (raw is ProjectArgs)
                ? raw
                : Get.find<StartupProjectArgsService>().projectArgs;
        if (args == null) {
          throw StateError('Missing ProjectArgs.');
        }
        Get.put<ProjectSessionsControllerBase>(ProjectSessionsController(args: args));
      }),
    ),
    GetPage(name: DesignRoutes.settings, page: SettingsPage.new),
  ];
}
