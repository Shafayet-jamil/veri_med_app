import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veri_med_app/main.dart';

void main() {
  testWidgets('home screen offers image scanning and license lookup', (
    tester,
  ) async {
    await tester.pumpWidget(const MediCheckerApp());

    expect(find.text('MediChecker'), findsOneWidget);
    expect(find.text('Scan medicine package'), findsOneWidget);
    expect(find.text('Look up by DAR / MA number'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Find license details'), findsOneWidget);
  });

  testWidgets('results display medicine details and extracted text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MedicineResultCard(
            result: {
              'match_found': true,
              'brand_name': 'Sample Medicine',
              'dar_number': '481-0003-034',
              'extracted_text': 'Sample label text',
            },
          ),
        ),
      ),
    );

    expect(find.text('Medicine details'), findsOneWidget);
    expect(find.text('Sample Medicine'), findsOneWidget);
    expect(find.text('481-0003-034'), findsOneWidget);
    expect(find.text('Sample label text'), findsOneWidget);
  });
}
