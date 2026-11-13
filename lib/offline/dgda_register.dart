/// The DGDA medicine and manufacturer registers, and lookup by DAR / MA
/// number and MFG licence number. A port of `mediCheker/lookup.py`.
library;

/// One row of a register. Medicine rows have "Company", "Trade Name",
/// "Generic Name With Strength", "Dosage Form", "DAR No"; company details
/// ("Address", "Bio_3", "NonBio_3", "Validity", "Status") are merged in.
typedef Row = Map<String, String>;

// "MFG Lic No. 379 & 119": one or more 3-digit manufacturer licence numbers.
// Each number must stand alone, and follow the label closely.
final mfgLicencePattern = RegExp(
  r'(?:mfg|mig)[\s.:]*lic[\s.:]*nos?[^\d]{0,10}'
  r'(\d{3}(?!\d)(?:\s*&\s*\d{3}(?!\d))*)',
  caseSensitive: false,
);

List<String> extractMfgLicenceNumbers(String text) {
  final match = mfgLicencePattern.firstMatch(text);
  if (match == null) return [];
  return RegExp(r'\d{3}')
      .allMatches(match.group(1)!)
      .map((m) => m.group(0)!)
      .toList();
}

String extract3Digit(String value) {
  final match = RegExp(r'\b(\d{3})\b').firstMatch(value.trim());
  return match?.group(1) ?? value.trim();
}

/// Pads the middle part to 4 digits, as stored in the DGDA database:
/// "353-41-023" -> "353-0041-023".
String normalizeMaNumber(String maNumber) {
  final match = RegExp(r'^(\d+)-(\d{1,3})-(\d+)$').firstMatch(maNumber.trim());
  if (match == null) return maNumber;
  return '${match.group(1)}-${match.group(2)!.padLeft(4, '0')}-${match.group(3)}';
}

String? extractAndNormalizeDarMaNumber(String text) {
  final labeled = RegExp(
    r'(?:DAR|MA|D[A4]R|OAR)[\s.:\-]*(?:No\.?[\s.:\-]*)?'
    r'(\d{2,4}[\s.:\-]+\d{2,5}[\s.:\-]+\d{2,5})',
    caseSensitive: false,
  ).firstMatch(text);
  if (labeled != null) {
    final standardized = labeled
        .group(1)!
        .replaceAll(RegExp(r'[\s.:]'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return normalizeMaNumber(standardized);
  }
  final unlabeled =
      RegExp(r'(\d{2,4})[\s.:\-]+(\d{2,5})[\s.:\-]+(\d{2,5})').firstMatch(text);
  if (unlabeled != null) {
    return normalizeMaNumber(
        '${unlabeled.group(1)}-${unlabeled.group(2)}-${unlabeled.group(3)}');
  }
  return null;
}

class DgdaRegister {
  DgdaRegister(List<Row> medicines, List<Row> companies)
      : medicines = [
          for (final m in medicines)
            {...m, '_company_key': (m['Company'] ?? '').toLowerCase().trim()},
        ],
        companies = [
          for (final c in companies)
            {
              ...c,
              'Bio_3': extract3Digit(c['License No (Biological)'] ?? ''),
              'NonBio_3': extract3Digit(c['License No (Non Biological)'] ?? ''),
              '_company_key': (c['Company'] ?? '').toLowerCase().trim(),
            },
        ] {
    for (final c in this.companies) {
      _companyByKey.putIfAbsent(c['_company_key']!, () => c);
    }
    for (var i = 0; i < this.medicines.length; i++) {
      _rowsByDar.putIfAbsent(this.medicines[i]['DAR No']!.trim(), () => []).add(i);
    }
  }

  final List<Row> medicines;
  final List<Row> companies;
  final _companyByKey = <String, Row>{};
  final _rowsByDar = <String, List<int>>{};

  static const _companyColumns = [
    'Address', 'Bio_3', 'NonBio_3', 'Validity', 'Status'
  ];

  /// Medicine row [index] with its manufacturer's licence details merged in
  /// (left join on the company name).
  Row withCompany(int index) {
    final med = medicines[index];
    final company = _companyByKey[med['_company_key']];
    return {
      ...med,
      for (final col in _companyColumns) col: company?[col] ?? '',
    };
  }

  List<Row> lookupByDar(String darQuery) =>
      [for (final i in _rowsByDar[darQuery.trim()] ?? const <int>[]) withCompany(i)];

  List<int> rowIndexesByDar(String dar) => _rowsByDar[dar.trim()] ?? const [];

  List<Row> findCompaniesByMfgNo(List<String> numbers) => [
        for (final c in companies)
          if (numbers.contains(c['Bio_3']) || numbers.contains(c['NonBio_3'])) c,
      ];

  /// The product of [rows] whose trade name appears in [text] as whole
  /// word(s), preferring the longest name ("Napa Extra" over "Napa").
  int? _productNamedInText(List<int> rows, String text) {
    final lower = text.toLowerCase();
    int? best;
    var bestLen = 0;
    for (final i in rows) {
      final name = medicines[i]['Trade Name']!.trim().toLowerCase();
      if (name.length < 3 || name.length <= bestLen) continue;
      if (RegExp('(?<![a-z0-9])${RegExp.escape(name)}(?![a-z0-9])')
          .hasMatch(lower)) {
        best = i;
        bestLen = name.length;
      }
    }
    return best;
  }

  /// Finds the registration record for OCR [ocrText]: by DAR / MA number
  /// and MFG licence number together, then DAR / MA alone, then MFG licence
  /// alone (which may only identify the manufacturer). Null if nothing.
  Row? runLookup(String ocrText) {
    final query = ocrText.trim();
    final mfg = extractMfgLicenceNumbers(query);
    final dar = extractAndNormalizeDarMaNumber(query);

    if (mfg.isNotEmpty && dar != null) {
      for (final row in lookupByDar(dar)) {
        if (mfg.contains(row['Bio_3']) || mfg.contains(row['NonBio_3'])) {
          return row;
        }
      }
    }
    // The DAR/MA number identifies one medicine, so it is tried before the
    // MFG licence number, which only identifies the manufacturer.
    if (dar != null) {
      final rows = lookupByDar(dar);
      if (rows.isNotEmpty) return rows.first;
    }
    if (mfg.isNotEmpty) {
      final matched = findCompaniesByMfgNo(mfg);
      if (matched.isNotEmpty) {
        final company = matched.first;
        final key = company['_company_key'];
        final rows = [
          for (var i = 0; i < medicines.length; i++)
            if (medicines[i]['_company_key'] == key) i,
        ];
        final product = _productNamedInText(rows, query);
        if (product != null) return withCompany(product);
        // Only the manufacturer is known: return the company record alone.
        return Map.of(company);
      }
    }
    return null;
  }
}
