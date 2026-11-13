/// Compares the text read from a package with its DGDA record.
/// A port of `mediCheker/verification.py`.
///
/// Each check is `match`, `mismatch` or `not_visible`. Only details that
/// were actually read count towards the score: a detail missing from the
/// photo is not evidence that the medicine is fake.
library;

import 'dgda_register.dart';

const _match = 'match';
const _mismatch = 'mismatch';
const _notVisible = 'not_visible';

final _strength =
    RegExp(r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu).*', caseSensitive: false);

const photoTip =
    'For a fuller check, photograph the side of the pack that shows the '
    'brand name, the DAR / MA number and the MFG licence number, in good '
    'light.';

String _get(Map<String, dynamic> row, List<String> keys) {
  for (final key in keys) {
    final value = row[key]?.toString().trim() ?? '';
    if (value.isNotEmpty && value.toLowerCase() != 'nan') return value;
  }
  return '';
}

Map<String, dynamic> _check(String field, String status, String extracted,
        String registered, int weight) =>
    {
      'field': field,
      'status': status,
      'match': status == _match,
      'extracted': status != _notVisible ? extracted : '(not visible)',
      'registered': registered,
      'weight': weight,
    };

String _findInText(String ocrLower, String target) =>
    ocrLower.contains(target) ? target : '';

Map<String, dynamic> computeVerification(
    String extractedText, Map<String, dynamic> dbRow,
    {Map<String, dynamic>? nameCheck}) {
  final checks = <Map<String, dynamic>>[];
  final ocrLower = extractedText.toLowerCase();

  final darDb = _get(dbRow, ['DAR No', 'dar_number']);
  if (darDb.isNotEmpty) {
    final darRead = extractAndNormalizeDarMaNumber(extractedText);
    final status = darRead == null
        ? _notVisible
        : (darRead == darDb ? _match : _mismatch);
    checks.add(_check('DAR / MA Number', status, darRead ?? '', darDb, 30));
  }

  final tradeDb = _get(dbRow, ['Trade Name', 'brand_name']);
  String? misspelledName;
  if (tradeDb.isNotEmpty) {
    if (nameCheck == null) {
      final found = _findInText(ocrLower, tradeDb.toLowerCase());
      checks.add(_check('Brand / Trade Name',
          found.isNotEmpty ? _match : _notVisible, found, tradeDb, 20));
    } else {
      final status = switch (nameCheck['status']) {
        'exact' => _match,
        'misspelled' || 'other_brand' => _mismatch,
        _ => _notVisible,
      };
      final read = nameCheck['read_name']?.toString() ?? '';
      checks.add(_check('Brand / Trade Name', status, read, tradeDb, 20));
      if (nameCheck['status'] == 'misspelled') misspelledName = read;
    }
  }

  final companyDb = _get(dbRow, ['Company', 'manufacturer']);
  if (companyDb.isNotEmpty) {
    final ws = companyDb
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toList();
    final matched = ws.where(ocrLower.contains).toList();
    final needed = ws.length ~/ 2 > 1 ? ws.length ~/ 2 : 1;
    checks.add(_check('Manufacturer',
        matched.length >= needed ? _match : _notVisible,
        matched.join(' '), companyDb, 20));
  }

  final genericDb = _get(dbRow, ['Generic Name With Strength', 'generic_name']);
  final baseGeneric = genericDb.replaceAll(_strength, '').trim().toLowerCase();
  if (baseGeneric.isNotEmpty) {
    final found = _findInText(ocrLower, baseGeneric);
    checks.add(_check('Generic Name', found.isNotEmpty ? _match : _notVisible,
        found, genericDb, 15));
  }

  final licencesDb = {
    _get(dbRow, ['Bio_3', 'MFG Lic (Biological)', 'mfg_license_biological']),
    _get(dbRow,
        ['NonBio_3', 'MFG Lic (Non-Biological)', 'mfg_license_non_biological']),
  }..remove('');
  if (licencesDb.isNotEmpty) {
    final read = extractMfgLicenceNumbers(extractedText);
    final status = read.isEmpty
        ? _notVisible
        : (read.any(licencesDb.contains) ? _match : _mismatch);
    checks.add(_check('MFG License Number', status, read.join(', '),
        (licencesDb.toList()..sort()).join(', '), 15));
  }

  return _summarize(checks,
      isMedicineRecord: darDb.isNotEmpty || tradeDb.isNotEmpty,
      company: companyDb,
      misspelledName: misspelledName,
      registeredName: tradeDb);
}

Map<String, dynamic> _summarize(List<Map<String, dynamic>> checks,
    {required bool isMedicineRecord,
    required String company,
    String? misspelledName,
    String registeredName = ''}) {
  final read = checks.where((c) => c['status'] != _notVisible).toList();
  final matched = read.where((c) => c['status'] == _match).toList();
  final mismatched = read.where((c) => c['status'] == _mismatch).toList();

  int weight(List<Map<String, dynamic>> cs) =>
      cs.fold(0, (sum, c) => sum + (c['weight'] as int));
  final readWeight = weight(read);
  final score =
      readWeight > 0 ? (weight(matched) / readWeight * 100).round() : 0;

  String names(List<Map<String, dynamic>> items) {
    final labels = items.map((c) => c['field'] as String).toList();
    return labels.length == 1
        ? labels.first
        : '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
  }

  String verdict, label, description;
  if (read.isEmpty) {
    verdict = 'unverifiable';
    label = 'Cannot Verify';
    description = 'A registration record was found, but none of its details '
        'could be read clearly on the package. $photoTip';
  } else if (misspelledName != null) {
    verdict = 'name_misspelled';
    label = 'Likely Fake: Name Misspelled';
    description = 'The package reads "$misspelledName", but the registered '
        'medicine is spelled "$registeredName". A misspelled brand name is a '
        'common sign of a fake medicine. If the photo is blurry, retake it to '
        'rule out a misread; otherwise do not use the medicine and show it to '
        'a pharmacist.';
  } else if (mismatched.isNotEmpty) {
    if (score >= 50) {
      verdict = 'suspicious';
      label = 'Some Details Differ';
    } else {
      verdict = 'likely_counterfeit';
      label = 'Details Do Not Match';
    }
    description = 'The ${names(mismatched)} on the package '
        '${mismatched.length == 1 ? 'does' : 'do'} not match the official '
        'DGDA record. Check the medicine with a pharmacist before using it.';
  } else if (!isMedicineRecord) {
    verdict = 'manufacturer_only';
    label = 'Manufacturer Identified';
    description = 'The package matches the registered manufacturer $company, '
        'but its DAR / MA number could not be read, so the medicine itself '
        'was not checked. $photoTip';
  } else if (matched.length >= 2) {
    verdict = 'likely_genuine';
    label = 'Matches DGDA Record';
    description = '${matched.length} details read from the package match the '
        'official DGDA registration: ${names(matched)}. No conflicting '
        'details were found.';
  } else {
    verdict = 'partial_match';
    label = 'Registered, Partly Checked';
    description = 'The ${names(matched)} matches a registered medicine and '
        'nothing on the package contradicts it, but the other details could '
        'not be read. $photoTip';
  }

  return {
    'verification_score': score,
    'verdict': verdict,
    'verdict_label': label,
    'verdict_description': description,
    'checks': checks,
    'matched_fields': matched.length,
    'mismatched_fields': mismatched.length,
    'read_fields': read.length,
    'total_fields': checks.length,
  };
}
