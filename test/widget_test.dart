import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veri_med_app/main.dart';
import 'package:veri_med_app/services/medicine_api.dart';

/// A backend that answers every request without touching the network.
MedicineApi fakeApi() {
  return MedicineApi(
    client: MockClient((request) async {
      final body = switch (request.url.path) {
        '/medicine-names' => {
            'medicines': [
              {'trade_name': 'Napa', 'generic_name': 'Paracetamol'},
            ],
          },
        '/verify-license' => {
            'match_found': true,
            'dar_number': request.url.queryParameters['dar_number'],
            'brand_name': 'Sample Medicine',
            'manufacturer': 'Sample Pharma Ltd.',
          },
        _ => {'error': 'Not found'},
      };
      final status = body.containsKey('error') ? 404 : 200;
      return http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
    }),
  );
}

void main() {
  testWidgets('scan tab offers camera, gallery and scan actions', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('MediChecker'), findsOneWidget);
    expect(find.text('Scan medicine package'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Scan & Verify Authenticity'), findsOneWidget);

    // The scan button stays disabled until a photo is chosen.
    final scanButton = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Scan & Verify Authenticity'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(scanButton.onPressed, isNull);
  });

  testWidgets('bottom navigation shows all three tabs', (tester) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Lookup'), findsOneWidget);
    expect(find.text('Interactions'), findsOneWidget);
  });

  testWidgets('lookup tab finds a medicine by DAR / MA number', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lookup'));
    await tester.pumpAndSettle();

    expect(find.text('DAR / MA number lookup'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '481-0003-034');
    await tester.tap(find.text('Find License Details'));
    await tester.pumpAndSettle();

    expect(find.text('Medicine Details'), findsOneWidget);
    expect(find.text('Sample Medicine'), findsOneWidget);
    expect(find.text('481-0003-034'), findsWidgets);
    expect(find.text('Sample Pharma Ltd.'), findsOneWidget);
  });

  testWidgets('lookup tab asks for a number when the field is empty', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lookup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find License Details'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a DAR / MA license number.'), findsOneWidget);
  });

  testWidgets('result card shows medicine details and extracted text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MedicineResultCard(
              result: {
                'match_found': true,
                'brand_name': 'Sample Medicine',
                'dar_number': '481-0003-034',
                'extracted_text': 'Sample label text',
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('Medicine Details'), findsOneWidget);
    expect(find.text('Sample Medicine'), findsOneWidget);
    expect(find.text('481-0003-034'), findsOneWidget);
    expect(find.text('Sample label text'), findsOneWidget);
  });

  testWidgets('result card shows "No matching record" when nothing matched', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MedicineResultCard(result: {'match_found': false}),
        ),
      ),
    );

    expect(find.text('No matching record'), findsOneWidget);
  });
}
