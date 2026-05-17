import 'package:flutter_test/flutter_test.dart';

import 'package:aamina_mobile/main.dart';

void main() {
  testWidgets('App renders start button', (WidgetTester tester) async {
    await tester.pumpWidget(const AaminaApp());

    expect(find.text('Start Streaming'), findsOneWidget);
  });
}
