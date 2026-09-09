import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/main.dart';

void main() {
  testWidgets('NexusApp renders dashboard and navigation smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NexusApp());
    await tester.pump(const Duration(milliseconds: 100));

    // Verify app bar title
    expect(find.text('Nexus Universal Continuity'), findsOneWidget);

    // Verify navigation bar destinations
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('File Drop'), findsOneWidget);
    expect(find.text('Trackpad'), findsOneWidget);
    expect(find.text('Appunti'), findsOneWidget);
    expect(find.text('Impostazioni'), findsOneWidget);

    // Verify Private Listening exists
    expect(find.text('Private Listening (Audio Relay)'), findsOneWidget);
  });
}
