import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_snackbar.dart';

Widget _app({required Widget home}) => MaterialApp(home: home);

void main() {
  testWidgets('the Queued bar (it has an action) closes by itself instead of sticking', (tester) async {
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQueuedForUploadSnackBar(context, 'Queued a.insv for upload'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Queued a.insv for upload'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Queued a.insv for upload'), findsNothing);
  });

  testWidgets('View still works after the page that showed the bar has been left', (tester) async {
    await tester.pumpWidget(
      _app(
        home: Builder(
          builder: (home) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(home).push(
                MaterialPageRoute(
                  builder: (_) => Builder(
                    builder: (page) => Scaffold(
                      body: TextButton(
                        onPressed: () {
                          showQueuedForUploadSnackBar(
                            page,
                            'Queued b.insv for upload',
                            pageBuilder: (_) => const Scaffold(body: Text('IMPORT PAGE')),
                          );
                          Navigator.of(page).pop(); // leave the page; the bar outlives it
                        },
                        child: const Text('queue and leave'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open page'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('queue and leave'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('open page'), findsOneWidget); // back on the first page
    expect(find.text('Queued b.insv for upload'), findsOneWidget); // bar survived the page

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('IMPORT PAGE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second Queued bar replaces the first instead of queuing behind it', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    showQueuedForUploadSnackBar(ctx, 'first');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    showQueuedForUploadSnackBar(ctx, 'second');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });
}
