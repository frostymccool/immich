import 'package:flutter/material.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';

/// "Queued … for upload" confirmation with a "View" action that opens the import page.
///
/// [pageBuilder] only exists so tests can avoid building the real import page.
///
/// Two traps this avoids:
/// - Flutter keeps a SnackBar that has an action on screen until dismissed by default
///   (`persist` defaults to `action != null`), so the bar used to stick across pages and cover
///   their buttons. It now auto-dismisses and replaces any bar already showing.
/// - The bar lives in the root ScaffoldMessenger and can outlive the page that showed it, so the
///   action must not use that page's BuildContext (deactivated by then, so "View" silently did
///   nothing). The NavigatorState is captured up front instead.
void showQueuedForUploadSnackBar(BuildContext context, String message, {WidgetBuilder? pageBuilder}) {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        persist: false,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'View',
          onPressed: () {
            messenger.hideCurrentSnackBar();
            if (navigator.mounted) {
              navigator.push(MaterialPageRoute(builder: pageBuilder ?? (_) => const CopypartyImportPage()));
            }
          },
        ),
      ),
    );
}
