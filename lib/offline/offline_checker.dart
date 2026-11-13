/// Everything the Python server did, on the phone: identify a medicine from
/// OCR text, check it against DGDA, look up DAR numbers and names, and check
/// interactions. Every method returns the same JSON-shaped maps as the
/// server endpoints, so the screens work with either.
library;

import 'csv_table.dart';
import 'dgda_register.dart';
import 'interactions.dart';
import 'name_check.dart';
import 'verification.dart';

class OfflineChecker {
  OfflineChecker({
    required String medicineCsv,
    required String companyCsv,
    required String interactionsCsv,
  }) : register = DgdaRegister(parseCsv(medicineCsv), parseCsv(companyCsv)),
       _interactionRows = parseCsv(interactionsCsv) {
    brands = BrandIndex(register);
    interactions = InteractionChecker(_interactionRows);
  }

  final DgdaRegister register;
  final List<Map<String, String>> _interactionRows;
  late final BrandIndex brands;
  late final InteractionChecker interactions;
  List<Map<String, String>>? _names;

  static Map<String, dynamic> medicineDetails(Row row, [String? darNumber]) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = row[k] ?? '';
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    return {
      'match_found': true,
      'dar_number': pick(['DAR No']).isNotEmpty ? pick(['DAR No']) : (darNumber ?? ''),
      'brand_name': pick(['Trade Name', 'Brand Name']),
      'generic_name': pick(['Generic Name With Strength', 'Generic Name']),
      'manufacturer': pick(['Company', 'Manufacturer']),
      'strength': pick(['Strength']),
      'dosage_form': pick(['Dosage Form']),
      'status': pick(['Status', 'Validity']),
      'validity': pick(['Validity']),
      'description': pick(['Address']),
      'mfg_license_biological': pick(['Bio_3']),
      'mfg_license_non_biological': pick(['NonBio_3']),
    };
  }

  /// The registration record of medicine row [index], with licence details.
  Row recordForRow(int index) {
    final dar = register.medicines[index]['DAR No']!;
    final rows = register.lookupByDar(dar);
    if (rows.isEmpty) return register.withCompany(index);
    final trade = register.medicines[index]['Trade Name'];
    return rows.firstWhere((r) => r['Trade Name'] == trade,
        orElse: () => rows.first);
  }

  Map<String, dynamic> _brandCheckForRecord(String text, String tradeName) {
    final check = brands.check(text, expectedBrand: tradeName);
    if (check.status == notFound) {
      final other = brands.check(text);
      if (other.status == exact && other.rowIndex != null) {
        final otherFirst = register.medicines[other.rowIndex!]['Trade Name']!
            .split(RegExp(r'\s+'))
            .first
            .toLowerCase();
        final ownFirst = tradeName.split(RegExp(r'\s+')).first.toLowerCase();
        if (otherFirst != ownFirst) {
          return {
            ...other.toJson(),
            'status': 'other_brand',
            'registered_name': tradeName,
          };
        }
      }
    }
    return check.toJson();
  }

  static Map<String, dynamic> get noRecordVerification => {
        'verification_score': 0,
        'verdict': 'no_record',
        'verdict_label': 'Could Not Read the Package',
        'verdict_description':
            'Too little text could be read from this photo to check the '
                'medicine. Retake the photo of the side that shows the brand '
                'name, in good light and in focus, or type the DAR / MA number '
                'in the Lookup tab.',
        'checks': <Map<String, dynamic>>[],
        'matched_fields': 0,
        'mismatched_fields': 0,
        'read_fields': 0,
        'total_fields': 0,
      };

  static Map<String, dynamic> _notRegisteredVerification(
      List<String> suggestions) {
    var description = 'No medicine name, DAR / MA number or MFG licence number '
        'on this package matches the official DGDA register of medicines. A '
        'medicine that is not registered is treated as fake: do not use it, '
        'and show it to a pharmacist.';
    if (suggestions.isNotEmpty) {
      description +=
          ' Closest registered names: ${suggestions.take(3).join(', ')}.';
    }
    description += ' If the brand name is not in the photo or the photo is '
        'blurry, retake it showing the front of the pack.';
    return {
      ...noRecordVerification,
      'verdict': 'not_registered',
      'verdict_label': 'Likely Fake: Not Registered',
      'verdict_description': description,
    };
  }

  /// Identifies the medicine in OCR [text] and checks it against DGDA: by
  /// DAR / MA and MFG licence numbers first, then by the brand name.
  Map<String, dynamic> identifyAndVerify(String text) {
    var row = register.runLookup(text);
    if (row != null) {
      var response = medicineDetails(row);
      Map<String, dynamic>? name;
      if ((row['DAR No'] ?? '').isNotEmpty) {
        response['match_type'] = 'medicine';
        name = _brandCheckForRecord(text, row['Trade Name'] ?? '');
      } else {
        // Only the manufacturer is known: look for one of its brands,
        // possibly misspelled.
        final brand = brands.check(text);
        if (brand.rowIndex != null) {
          final record = recordForRow(brand.rowIndex!);
          final key = (record['Company'] ?? '').toLowerCase().trim();
          if (key.isNotEmpty &&
              key == (row['Company'] ?? '').toLowerCase().trim()) {
            row = record;
            response = medicineDetails(row)..['match_type'] = 'medicine';
            name = brand.toJson();
          }
        }
        response.putIfAbsent('match_type', () => 'manufacturer');
      }
      response['name_check'] = name;
      response['verification'] = computeVerification(text, row, nameCheck: name);
      return response;
    }

    final name = brands.check(text);
    if (name.rowIndex != null) {
      final record = recordForRow(name.rowIndex!);
      return medicineDetails(record)
        ..['match_type'] = 'brand_name'
        ..['name_check'] = name.toJson()
        ..['verification'] =
            computeVerification(text, record, nameCheck: name.toJson());
    }

    return {
      'match_found': false,
      'match_type': 'none',
      'status': name.status == notFound ? 'Not registered' : 'No matching record',
      'name_check': name.toJson(),
      'verification': name.status == notFound
          ? _notRegisteredVerification(name.suggestions)
          : noRecordVerification,
    };
  }

  /// DAR / MA number lookup. Null when the number is not registered.
  Map<String, dynamic>? verifyLicense(String darNumber) {
    final rows = register.lookupByDar(darNumber);
    final row = rows.isNotEmpty ? rows.first : register.runLookup(darNumber);
    return row == null ? null : medicineDetails(row, darNumber);
  }

  /// Is a typed medicine name registered? Same shape as `/verify-name`.
  Map<String, dynamic> verifyName(String name) {
    final check = brands.lookupName(name);
    if (check.rowIndex == null) {
      var description =
          '"${name.trim()}" is not a medicine name registered with DGDA.';
      if (check.suggestions.isNotEmpty) {
        description += ' Did you mean: ${check.suggestions.join(', ')}?';
      }
      return {
        'match_found': false,
        'brand_name': name.trim(),
        'status': 'Not registered',
        'description': description,
        'name_check': check.toJson(),
      };
    }
    return medicineDetails(recordForRow(check.rowIndex!))
      ..['name_check'] = check.toJson();
  }

  List<Map<String, String>> get medicineNameList =>
      _names ??= medicineNames(register.medicines);

  Map<String, dynamic> checkInteractions(List<String> medicines) {
    final results = interactions.check(medicines);
    return {
      'interactions_found': results.isNotEmpty,
      'interaction_count': results.length,
      'interactions': results,
      'medicines_checked': medicines,
      'sources': interactions.sources,
    };
  }
}

// ── OCR text cleanup (from phase2_ocr.py) ────────────────────────────────────

const _ocrCorrections = [
  (r'\bMlG\b', 'MFG'),
  (r'\bMIG\b', 'MFG'),
  (r'\bL[1l]c\b', 'Lic'),
  (r'\bN[0o]\b', 'No'),
  (r'\bN[0o]\.\b', 'No.'),
  (r'\bDAF\b', 'DAR'),
  (r'\bOAR\b', 'DAR'),
  (r'\bD[A4]R\b', 'DAR'),
];

String _fixOcrErrors(String text) {
  for (final (pattern, replacement) in _ocrCorrections) {
    text = text.replaceAll(RegExp(pattern, caseSensitive: false), replacement);
  }
  return text;
}

String _cleanText(String text) => text
    .trim()
    .replaceAll(RegExp(r'[^\x20-\x7E]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Cleans OCR lines (already in reading order): drops noise, fixes common
/// misreads ("OAR No" -> "DAR No") and near-duplicate lines.
List<String> cleanOcrLines(Iterable<String> lines) {
  final result = <String>[];
  final seen = <String>[];
  for (final raw in lines) {
    final cleaned = _cleanText(raw);
    if (cleaned.length < 2) continue;
    final text = _fixOcrErrors(cleaned);
    final lower = text.toLowerCase();
    if (seen.any((s) => s.contains(lower) || lower.contains(s))) continue;
    result.add(text);
    seen.add(lower);
  }
  return result;
}
