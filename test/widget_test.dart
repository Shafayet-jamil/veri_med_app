import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veri_med_app/main.dart';
import 'package:veri_med_app/services/medicine_api.dart';
import 'package:veri_med_app/widgets/verification_badge.dart';

/// A backend that answers every request without touching the network.
MedicineApi fakeApi() {
  return MedicineApi(
    client: MockClient((request) async {
      final body = switch (request.url.path) {
        '/medicine-names' => {
            'medicines': [
              {'trade_name': 'Napa', 'generic_name': 'Paracetamol'},
              {'trade_name': 'Sergel', 'generic_name': 'Esomeprazole'},
              {'trade_name': 'Clopid', 'generic_name': 'Clopidogrel'},
            ],
          },
        '/check-interactions' => {
            'interactions_found': true,
            'interaction_count': 1,
            'interactions': [
              {
                'drug_a': 'Esomeprazole',
                'drug_b': 'Clopidogrel',
                'severity': 'severe',
                'effect': 'DDInter lists an interaction between these drugs '
                    '(severity: Major).',
                'recommendation':
                    'Avoid this combination unless a doctor has approved it.',
                'source': 'DDInter',
              },
            ],
            'sources': [
              {
                'name': 'DDInter',
                'license': 'CC BY-NC-SA 4.0 (non-commercial use only)',
                'url': 'https://ddinter.scbdd.com/',
              },
            ],
          },
        '/verify-name' => request.url.queryParameters['name'] == 'Napa'
            ? {
                'match_found': true,
                'brand_name': 'Napa',
                'manufacturer': 'Beximco Pharmaceuticals Ltd.',
                'name_check': {'status': 'exact', 'suggestions': []},
              }
            : {
                'match_found': false,
                'status': 'Not registered',
                'description': '"Nappa" is not a medicine name registered '
                    'with DGDA. Did you mean: Napa?',
                'name_check': {
                  'status': 'not_found',
                  'suggestions': ['Napa'],
                },
              },
        '/verify-license' => {
            'match_found': true,
            'dar_number': request.url.queryParameters['dar_number'],
            'brand_name': 'Sample Medicine',
            'manufacturer': 'Sample Pharma Ltd.',
          },
        _ => {'error': 'Not found'},
      };
      final status =
          body.containsKey('error') || body['match_found'] == false ? 404 : 200;
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
    expect(find.text('For the best result'), findsOneWidget);

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

    expect(find.text('DAR / MA number or name'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '481-0003-034');
    await tester.tap(find.text('Find Medicine'));
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
    await tester.tap(find.text('Find Medicine'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a DAR / MA number or a medicine name.'),
        findsOneWidget);
  });

  testWidgets('lookup tab finds a registered medicine by name', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lookup'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Napa');
    await tester.tap(find.text('Find Medicine'));
    await tester.pumpAndSettle();

    expect(find.text('Medicine Details'), findsOneWidget);
    expect(find.text('Beximco Pharmaceuticals Ltd.'), findsOneWidget);
  });

  testWidgets('lookup tab says a misspelled name is not registered', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lookup'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Nappa');
    await tester.tap(find.text('Find Medicine'));
    await tester.pumpAndSettle();

    expect(find.text('Not in DGDA Register'), findsOneWidget);
    expect(find.textContaining('Did you mean: Napa?'), findsOneWidget);
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

  testWidgets('result card says when nothing is registered', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MedicineResultCard(result: {'match_found': false}),
        ),
      ),
    );

    expect(find.text('Not in DGDA Register'), findsOneWidget);
  });

  testWidgets('result card says when only the manufacturer was found', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MedicineResultCard(
            result: {
              'match_found': true,
              'match_type': 'manufacturer',
              'manufacturer': 'Beximco Pharmaceuticals Ltd.',
            },
          ),
        ),
      ),
    );

    expect(find.text('Manufacturer Found'), findsOneWidget);
    expect(find.text('Medicine Details'), findsNothing);
    expect(find.text('Beximco Pharmaceuticals Ltd.'), findsOneWidget);
  });

  Future<void> pumpBadge(WidgetTester tester, Map<String, dynamic> v) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VerificationBadge(verification: v),
          ),
        ),
      ),
    );
  }

  testWidgets('partial check shows no percentage and marks unread fields', (
    tester,
  ) async {
    await pumpBadge(tester, {
      'verification_score': 100,
      'verdict': 'partial_match',
      'verdict_label': 'Registered, Partly Checked',
      'verdict_description': 'Only the DAR number could be read.',
      'matched_fields': 1,
      'mismatched_fields': 0,
      'read_fields': 1,
      'total_fields': 2,
      'checks': [
        {
          'field': 'DAR / MA Number',
          'status': 'match',
          'extracted': '353-0041-023',
          'registered': '353-0041-023',
        },
        {
          'field': 'Brand / Trade Name',
          'status': 'not_visible',
          'extracted': '(not visible)',
          'registered': 'Furoclav 500',
        },
      ],
    });

    expect(find.text('Registered, Partly Checked'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(find.text('1 match · 1 not visible in photo'), findsOneWidget);
    expect(find.text('Brand / Trade Name: not visible in photo'),
        findsOneWidget);
  });

  testWidgets('full check shows the score and flags mismatches', (
    tester,
  ) async {
    await pumpBadge(tester, {
      'verification_score': 85,
      'verdict': 'suspicious',
      'verdict_label': 'Some Details Differ',
      'verdict_description': 'The MFG License Number does not match.',
      'matched_fields': 4,
      'mismatched_fields': 1,
      'read_fields': 5,
      'total_fields': 5,
      'checks': [
        {
          'field': 'MFG License Number',
          'status': 'mismatch',
          'extracted': '999',
          'registered': '119, 379',
        },
      ],
    });

    expect(find.text('85%'), findsOneWidget);
    expect(find.text('4 match · 1 differ'), findsOneWidget);
    expect(find.text('MFG License Number: does not match'), findsOneWidget);
  });

  testWidgets('misspelled name is shown as likely fake', (tester) async {
    await pumpBadge(tester, {
      'verification_score': 75,
      'verdict': 'name_misspelled',
      'verdict_label': 'Likely Fake: Name Misspelled',
      'verdict_description':
          'The package reads "nappa", but the registered medicine is spelled '
              '"Napa".',
      'matched_fields': 3,
      'mismatched_fields': 1,
      'read_fields': 4,
      'total_fields': 5,
      'checks': [
        {
          'field': 'Brand / Trade Name',
          'status': 'mismatch',
          'extracted': 'nappa',
          'registered': 'Napa',
        },
      ],
    });

    expect(find.text('Likely Fake: Name Misspelled'), findsOneWidget);
    expect(find.byIcon(Icons.spellcheck), findsOneWidget);
    expect(find.text('Brand / Trade Name: does not match'), findsOneWidget);
  });

  testWidgets('interaction check shows severity, source and attribution', (
    tester,
  ) async {
    await tester.pumpWidget(MediCheckerApp(api: fakeApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Interactions'));
    await tester.pumpAndSettle();

    final search = find.byType(TextField).last;
    await tester.enterText(search, 'Serg');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sergel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sergel'));
    await tester.pumpAndSettle();
    await tester.enterText(search, 'Clop');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Clopid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clopid'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Check interactions'));
    await tester.tap(find.text('Check interactions'));
    await tester.pumpAndSettle();

    // Both medicines were selected before checking.
    expect(find.text('Selected medicines (2)'), findsOneWidget);

    final list = find.byType(Scrollable).hitTestable().first;
    await tester.scrollUntilVisible(find.textContaining('Data sources'), 300,
        scrollable: list);
    await tester.pumpAndSettle();

    expect(find.text('Esomeprazole + Clopidogrel'), findsOneWidget);
    expect(find.text('SEVERE'), findsOneWidget);
    expect(find.text('Source: DDInter'), findsOneWidget);
    expect(find.textContaining('CC BY-NC-SA 4.0'), findsOneWidget);
  });
}
