// The on-device checker, against the real DGDA data. These mirror the
// Python backend tests (mediCheker/tests), so both give the same answers.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:veri_med_app/offline/csv_table.dart';
import 'package:veri_med_app/offline/dgda_register.dart';
import 'package:veri_med_app/offline/name_check.dart';
import 'package:veri_med_app/offline/offline_checker.dart';
import 'package:veri_med_app/services/medicine_api.dart';
import 'package:veri_med_app/services/offline_medicine_service.dart';

const napaDar = '186-0479-006';

String _read(String path) => File(path).readAsStringSync();

void main() {
  late OfflineChecker checker;

  setUpAll(() {
    checker = OfflineChecker(
      medicineCsv: _read(medicineCsvAsset),
      companyCsv: _read(companyCsvAsset),
      interactionsCsv: _read(interactionsCsvAsset),
    );
  });

  Map<String, dynamic> scan(List<String> lines) =>
      checker.identifyAndVerify(cleanOcrLines(lines).join(' '));

  group('CSV and register', () {
    test('parses quoted fields', () {
      final rows = parseCsv('a,"b c","d ""e"""\n1,"2,3",4\n');
      expect(rows.single, {'a': '1', 'b c': '2,3', 'd "e"': '4'});
    });

    test('loads the whole register', () {
      expect(checker.register.medicines.length, 41301);
    });

    test('DAR numbers are normalised like the database', () {
      expect(extractAndNormalizeDarMaNumber('MA No. 353-41-023'),
          '353-0041-023');
      expect(extractMfgLicenceNumbers('Mfg. Lic. No. 379 & 119'),
          ['379', '119']);
    });
  });

  group('lookup', () {
    test('finds a medicine by DAR number', () {
      final body = checker.verifyLicense(napaDar)!;
      expect(body['brand_name'], 'Napa');
      expect(body['manufacturer'], 'Beximco Pharmaceuticals Ltd.');
      expect(body['mfg_license_non_biological'], '379');
    });

    test('accepts the short printed number', () {
      final body = checker.verifyLicense('353-41-023')!;
      expect(body['brand_name'], 'Furoclav 500');
      expect(body['dar_number'], '353-0041-023');
    });

    test('unknown number is not found', () {
      expect(checker.verifyLicense('000-0000-000'), isNull);
    });

    test('typed name', () {
      expect(checker.verifyName('napa')['brand_name'], 'Napa');
      final typo = checker.verifyName('Nappa');
      expect(typo['match_found'], false);
      expect((typo['name_check'] as Map)['suggestions'], contains('Napa'));
    });
  });

  group('scan', () {
    test('genuine label', () {
      final body = scan(['Napa', 'Paracetamol 500 mg',
        'Beximco Pharmaceuticals Ltd.', 'DAR No. $napaDar',
        'Mfg. Lic. No. 379']);
      expect(body['dar_number'], napaDar);
      expect(body['match_type'], 'medicine');
      expect((body['verification'] as Map)['verdict'], 'likely_genuine');
    });

    test('partial label is not called counterfeit', () {
      final body = scan(['MA No. 353-41-023', 'Antibiotic']);
      expect(body['brand_name'], 'Furoclav 500');
      expect((body['verification'] as Map)['verdict'], 'partial_match');
    });

    test('manufacturer only', () {
      final body = scan(['Mfg. Lic. No. 379']);
      expect(body['match_type'], 'manufacturer');
      expect(body['manufacturer'], 'Beximco Pharmaceuticals Ltd.');
      expect((body['verification'] as Map)['verdict'], 'manufacturer_only');
    });

    test('unreadable label asks for a retake', () {
      final body = scan(['blurry', 'nothing useful']);
      expect(body['match_found'], false);
      expect((body['verification'] as Map)['verdict'], 'no_record');
    });

    test('medicine identified by its brand name alone', () {
      final body = scan(['Napa', 'Paracetamol 500 mg Tablet',
        'Beximco Pharmaceuticals Ltd.']);
      expect(body['match_type'], 'brand_name');
      expect(body['dar_number'], napaDar);
      expect((body['verification'] as Map)['verdict'], 'likely_genuine');
    });

    test('misspelled brand is likely fake', () {
      final body = scan(['Nappa', 'Paracetamol 500 mg Tablet',
        'Beximco Pharmaceuticals Ltd.']);
      expect(body['brand_name'], 'Napa');
      expect((body['name_check'] as Map)['read_name'], 'nappa');
      expect((body['verification'] as Map)['verdict'], 'name_misspelled');
    });

    test('misspelled brand with copied numbers is likely fake', () {
      final body = scan(['Nappa', 'Paracetamol 500 mg',
        'Beximco Pharmaceuticals Ltd.', 'DAR No. $napaDar',
        'Mfg. Lic. No. 379']);
      expect((body['verification'] as Map)['verdict'], 'name_misspelled');
    });

    test('numbers of another brand are flagged', () {
      final body = scan(['Biltin', 'Bilastine 20 mg Tablet',
        'Eskayef Pharmaceuticals', 'DAR No. $napaDar']);
      final checks = (body['verification'] as Map)['checks'] as List;
      final brand = checks.firstWhere((c) => c['field'] == 'Brand / Trade Name');
      expect(brand['status'], 'mismatch');
    });

    test('unregistered medicine is likely fake', () {
      final body = scan(['Zorbatex 500', 'Paracetamol tablet',
        'Healwell Pharma Ltd', 'Keep away from children']);
      expect(body['match_found'], false);
      expect((body['verification'] as Map)['verdict'], 'not_registered');
    });
  });

  group('name check', () {
    test('picks plain Napa, not Napa Rapid', () {
      final r = checker.brands.check(
          'Napa Paracetamol 500 mg Beximco Pharmaceuticals Ltd. Tablet');
      expect(r.status, exact);
      expect(checker.register.medicines[r.rowIndex!]['DAR No'], napaDar);
    });

    test('forgives OCR digit for letter', () {
      expect(checker.brands.check('Bi1tin Bilastine 20 mg Tablet').status,
          exact);
    });

    test('generic name alone is not a brand', () {
      expect(
          checker.brands
              .check('Each film coated tablet contains Paracetamol BP 500 mg '
                  'Store in a cool dry place')
              .status,
          notFound);
    });

    // Real OCR output from dataset/sample-8.jpeg (a genuine pack).
    test('stray letter is not a misspelling and strengths pick the product',
        () {
      final r = checker.brands.check([
        'Cefuroxime USP 5OOmg', '500', 'Clavulanic Acid BP 125mg:',
        'Vnive sity,', 'IFuroclav"', 'Cefuroxime USP SOOmg +',
        'RENATA Livited', 'WT', 'Clavulanic Acid BP 12Smg',
      ].join(' '));
      expect(r.status, exact);
      expect(r.registeredName, 'Furoclav 500');
    });

    test('ratio matches rapidfuzz', () {
      expect(ratio('nappa', 'napa').round(), 89);
      expect(levenshtein('furoclov', 'furoclav'), 1);
    });
  });

  group('interactions', () {
    test('known pair', () {
      final body = checker.checkInteractions(['Warfarin', 'Aspirin']);
      expect(body['interaction_count'], 1);
      expect((body['interactions'] as List).first['severity'], 'severe');
    });

    test('whole words only', () {
      expect(checker.checkInteractions(['Warfarin', 'Esomeprazole'])
          ['interaction_count'], 0);
    });

    test('combination product and salt names', () {
      expect(checker.checkInteractions(['Warfarin', 'Caffeine + Paracetamol'])
          ['interactions_found'], true);
      expect(checker.checkInteractions(
          ['Amlodipine Besilate 5 mg', 'Simvastatin 20 mg'])
          ['interaction_count'], 1);
    });

    test('medicine name list', () {
      expect(checker.medicineNameList.any((m) => m['trade_name'] == 'Napa'),
          true);
    });
  });

  group('OfflineMedicineService', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('scans a photo using the bundled assets', () async {
      final service = OfflineMedicineService(
        textReader: (_) async => ['Napa', 'Paracetamol 500 mg Tablet',
          'Beximco Pharmaceuticals Ltd.'],
        bundle: rootBundle,
      );
      final body = await service.scanMedicine(XFile('unused.jpg'));
      expect(body['brand_name'], 'Napa');
      expect(body['extracted_text'],
          'Napa | Paracetamol 500 mg Tablet | Beximco Pharmaceuticals Ltd.');
    });

    test('unknown DAR number is an error message', () async {
      final service = OfflineMedicineService(textReader: (_) async => []);
      expect(service.lookupLicense('000-0000-000'),
          throwsA(isA<MedicineApiException>()));
    });

    test('reading order follows rows', () {
      expect(
          sortLinesByPosition([
            ('right', 100, 200, 20),
            ('second row', 140, 0, 20),
            ('left', 104, 10, 20),
          ]),
          ['left', 'right', 'second row']);
    });
  });
}
