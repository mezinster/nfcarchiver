import 'package:flutter/widgets.dart';

import 'logger.dart';

/// Records screen changes as `nav` breadcrumbs, so a shared log shows which
/// screens preceded an error.
///
/// Only the route NAME is logged. `RouteSettings.toString()` would also print
/// `arguments`, which can carry user data, so an unnamed route (a dialog, a
/// bottom sheet) is logged by its type instead.
class LogNavigatorObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? route) =>
      route?.settings.name ?? '<unnamed ${route?.runtimeType}>';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      log.info('nav', 'open ${_name(route)}');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      log.info('nav', 'back to ${_name(previousRoute)}');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      log.info('nav', 'open ${_name(newRoute)}');
}
