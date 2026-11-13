/// Drug-drug interaction checks with the curated list
/// (`mediCheker/excelFile/drug_interactions.csv`). A port of
/// `mediCheker/interactions.py`. The optional DDInter data is not bundled
/// in the app: its licence is non-commercial and it is not in the repo.
library;

const curatedSource = {
  'name': 'MediChecker curated list',
  'license': '',
  'url': '',
};

/// British / INN name -> US name (used by some sources).
const nameAliases = {
  'paracetamol': 'acetaminophen',
  'aspirin': 'acetylsalicylic acid',
  'glibenclamide': 'glyburide',
  'frusemide': 'furosemide',
  'adrenaline': 'epinephrine',
  'noradrenaline': 'norepinephrine',
  'lignocaine': 'lidocaine',
  'pethidine': 'meperidine',
  'ciclosporin': 'cyclosporine',
  'colecalciferol': 'cholecalciferol',
  'sodium valproate': 'valproic acid',
  'valproate': 'valproic acid',
  'amoxycillin': 'amoxicillin',
  'cefalexin': 'cephalexin',
  'sulphamethoxazole': 'sulfamethoxazole',
  'dicycloverine': 'dicyclomine',
  'chlorphenamine': 'chlorpheniramine',
  'phenobarbitone': 'phenobarbital',
  'oestradiol': 'estradiol',
  'glyceryl trinitrate': 'nitroglycerin',
  'thiamazole': 'methimazole',
};

final _canonicalMap = {for (final e in nameAliases.entries) e.value: e.key};
String _canonical(String key) => _canonicalMap[key] ?? key;

final _strengthPattern = RegExp(
    r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu|mm|kg|liter|%)\b.*',
    caseSensitive: false);

RegExp _wordPattern(String name) =>
    RegExp('(?<![a-z0-9])${RegExp.escape(name)}(?![a-z0-9])');

bool _mentions(String name, String key) =>
    name.isNotEmpty && key.isNotEmpty && _wordPattern(key).hasMatch(name);

String extractBaseName(String genericWithStrength) {
  final cleaned = genericWithStrength.replaceAll(_strengthPattern, '').trim();
  return cleaned.isEmpty ? genericWithStrength.trim() : cleaned;
}

class InteractionChecker {
  InteractionChecker(List<Map<String, String>> curatedRows) {
    final seen = <String>{};
    for (final r in curatedRows) {
      final a = _canonical((r['drug_a'] ?? '').toLowerCase().trim());
      final b = _canonical((r['drug_b'] ?? '').toLowerCase().trim());
      if (a.isEmpty || b.isEmpty || a == b) continue;
      final pair = a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
      if (!seen.add(pair)) continue; // first row of a pair wins
      _rows.add({...r, 'source': curatedSource['name']!});
      _byPair.putIfAbsent(pair, () => []).add(_rows.length - 1);
      _keys..add(a)..add(b);
    }
    _patterns = [for (final k in _keys.toList()..sort()) (k, _wordPattern(k))];
  }

  final _rows = <Map<String, String>>[];
  final _byPair = <String, List<int>>{};
  final _keys = <String>{};
  late final List<(String, RegExp)> _patterns;

  List<Map<String, String>> get sources => _rows.isEmpty ? [] : [curatedSource];

  Set<String> _drugsIn(String name) {
    var text = name.toLowerCase().trim();
    final extra = [
      for (final e in _canonicalMap.entries)
        if (_mentions(text, e.key)) e.value,
    ];
    text = [text, ...extra].join(' | ');
    return {for (final (k, p) in _patterns) if (p.hasMatch(text)) k};
  }

  List<Map<String, dynamic>> check(List<String> drugNames) {
    final baseNames = [
      for (final n in drugNames) extractBaseName(n).toLowerCase().trim(),
    ];
    final drugs = [for (final n in baseNames) _drugsIn(n)];
    final found = <Map<String, dynamic>>[];
    final checked = <String>{};

    for (var i = 0; i < baseNames.length; i++) {
      for (var j = i + 1; j < baseNames.length; j++) {
        if (baseNames[i] == baseNames[j]) continue;
        final key = ([baseNames[i], baseNames[j]]..sort()).join('|');
        if (!checked.add(key)) continue;

        final rows = <int>{};
        for (final a in drugs[i]) {
          for (final b in drugs[j]) {
            if (a == b) continue;
            final pair = a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
            rows.addAll(_byPair[pair] ?? const []);
          }
        }
        for (final pos in rows.toList()..sort()) {
          final row = _rows[pos];
          found.add({
            'drug_a': drugNames[i],
            'drug_b': drugNames[j],
            'severity': row['severity'] ?? '',
            'effect': row['effect'] ?? '',
            'recommendation': row['recommendation'] ?? '',
            'source': row['source'] ?? '',
            'interacting_drugs': [row['drug_a'], row['drug_b']],
          });
        }
      }
    }
    const order = {'severe': 0, 'moderate': 1, 'mild': 2, 'unknown': 3};
    // List.sort is not stable; sort on (severity, original position).
    final indexed = found.asMap().entries.toList()
      ..sort((x, y) {
        final c = (order[(x.value['severity'] as String).toLowerCase()] ?? 4)
            .compareTo(order[(y.value['severity'] as String).toLowerCase()] ?? 4);
        return c != 0 ? c : x.key.compareTo(y.key);
      });
    return [for (final e in indexed) e.value];
  }
}

/// Unique (trade name, generic name) pairs for the interaction search box.
List<Map<String, String>> medicineNames(List<Map<String, String>> medicines) {
  final seen = <String>{};
  final names = <Map<String, String>>[];
  for (final m in medicines) {
    final trade = (m['Trade Name'] ?? '').trim();
    if (trade.isEmpty) continue;
    final full = (m['Generic Name With Strength'] ?? '').trim();
    final base = extractBaseName(full);
    if (!seen.add('${trade.toLowerCase()}|${base.toLowerCase()}')) continue;
    names.add({
      'trade_name': trade,
      'generic_name': base,
      'generic_name_with_strength': full,
    });
  }
  return names;
}
