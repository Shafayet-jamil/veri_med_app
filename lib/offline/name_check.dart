/// Checks the medicine name printed on a package against the DGDA register.
/// A port of `mediCheker/name_check.py`; see that file for the reasoning.
///
/// - `exact`       a registered brand name is spelled correctly on the pack
/// - `misspelled`  a word one or two letters away from a registered brand of
///                 the same maker / generic: a common sign of a counterfeit
/// - `not_found`   no word on the pack is a registered brand name
/// - `unreadable`  too little text was read to tell
library;

import 'dart:math' as math;

import 'dgda_register.dart';

const exact = 'exact';
const misspelled = 'misspelled';
const notFound = 'not_found';
const unreadable = 'unreadable';

/// Words printed on most packs that are also the first word of some
/// registered trade name. They never identify the medicine on their own.
final _commonWords = '''
tablet tablets tab capsule capsules cap caps injection inj syrup suspension
solution drops cream ointment gel powder oral film coated each contains
contain store keep children reach dry place below above light protect
pharmaceuticals pharmaceutical pharma limited ltd plc company industries
laboratories healthcare bangladesh dhaka gazipur tongi manufactured marketed
for use only dose directed physician prescription batch date expiry exp mfg
lic dar reg price retail strip pack box usp bp rx medicine drug the and
with plus extra forte rapid one active ingredient warning read leaflet
carefully composition indications temperature room cool sunlight moisture
not more than mrp vat taka made new pure sugar free adult child children
care life plus max day night junior kids baby vet bolus
'''
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toSet();

/// Fewer letters than this in the whole OCR text: the photo was not readable.
const minLettersToJudge = 20;

final _word = RegExp(r'[a-z0-9]+');
final _alpha = RegExp(r'^[a-z]+$');
final _letter = RegExp(r'[A-Za-z]');

List<String> words(String text) =>
    _word.allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();

bool _isAlpha(String s) => _alpha.hasMatch(s);

String _stripTrailingDigits(String s) => s.replaceFirst(RegExp(r'\d+$'), '');

/// First alphabetic word of a trade name ("Furoclav-125" -> "furoclav").
String brandOf(String tradeName) {
  final ws = words(tradeName);
  if (ws.isEmpty) return '';
  final word = _stripTrailingDigits(ws.first);
  return word.length >= 3 && _isAlpha(word) ? word : '';
}

const _digitToLetter = {'0': 'o', '1': 'l', '5': 's', '8': 'b', '6': 'g'};

/// The token, plus fixes for common OCR slips: digits read for letters
/// ("bi1tin" -> "biltin") and a strength glued on ("napa500" -> "napa").
List<String> ocrVariants(String token) {
  final variants = [token];
  final letters = token.split('').where((c) => _isAlpha(c)).length;
  if (letters > 0 && letters < token.length && letters / token.length >= 0.6) {
    variants.add(token.split('').map((c) => _digitToLetter[c] ?? c).join());
  }
  final stripped = _stripTrailingDigits(token);
  if (stripped != token && stripped.length >= 3) variants.add(stripped);
  return variants.toSet().where(_isAlpha).toList();
}

/// A pack edge or "|" next to a word is often read as one of these thin
/// letters glued to it: "IFuroclav" for "Furoclav".
const _strayStrokes = 'iljt';

/// Variants to try for an exact match: [ocrVariants] plus the word without a
/// thin stray letter at either end. Only used to *accept* a registered name.
List<String> _exactVariants(String token) {
  final variants = ocrVariants(token);
  for (final v in List.of(variants)) {
    if (v.length >= 5) {
      if (_strayStrokes.contains(v[0])) variants.add(v.substring(1));
      if (_strayStrokes.contains(v[v.length - 1])) {
        variants.add(v.substring(0, v.length - 1));
      }
    }
  }
  return variants.toSet().toList();
}

// OCR reads "500mg" as "5OOmg" or "SOOmg" and "125mg" as "12Smg".
final _ocrNumber = RegExp(
  r'\b[\dOoSsIl.]*\d[\dOoSsIl.]*(?=\s*(?:mg|ml|gm|mcg|g)\b)'
  r'|\b[OoSs\d][\dOoSs]+(?=\s*(?:mg|ml|gm|mcg)\b)',
);
const _numberFixes = {'O': '0', 'o': '0', 'S': '5', 's': '5', 'I': '1', 'l': '1'};

String fixNumbers(String text) => text.replaceAllMapped(
    _ocrNumber,
    (m) => m.group(0)!.split('').map((c) => _numberFixes[c] ?? c).join());

/// Levenshtein edit distance.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// Similarity 0-100 from the insert/delete distance, the same measure as
/// rapidfuzz's `fuzz.ratio` used by the Python backend.
double ratio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 100;
  var prev = List<int>.filled(b.length + 1, 0);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      cur[j] = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)
          ? prev[j - 1] + 1
          : math.max(prev[j], cur[j - 1]);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  final lcs = prev[b.length];
  return 100 * 2 * lcs / (a.length + b.length);
}

class NameCheckResult {
  NameCheckResult(
    this.status, {
    this.readName = '',
    this.registeredName = '',
    this.similarity = 0,
    this.rowIndex,
    List<String>? suggestions,
  }) : suggestions = suggestions ?? [];

  final String status;
  final String readName;
  final String registeredName;
  final int similarity;
  final int? rowIndex;
  List<String> suggestions;

  Map<String, dynamic> toJson() => {
        'status': status,
        'read_name': readName,
        'registered_name': registeredName,
        'similarity': similarity,
        'suggestions': suggestions,
      };
}

class _Candidate {
  _Candidate(this.row, this.brand, this.readAs, this.status, this.similarity,
      this.support, this.position,
      [this.weak = false]);

  final int row;
  final String brand;
  final String readAs;
  final String status;
  final int similarity;
  final int support;
  final int position;
  final bool weak;
}

int _compareLists(List<num> a, List<num> b) {
  for (var i = 0; i < a.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}

T _maxBy<T>(Iterable<T> items, List<num> Function(T) key) =>
    items.reduce((a, b) => _compareLists(key(b), key(a)) > 0 ? b : a);

class BrandIndex {
  BrandIndex(this.register) {
    final meds = register.medicines;
    for (var i = 0; i < meds.length; i++) {
      final brand = brandOf(meds[i]['Trade Name']!);
      if (brand.isNotEmpty) rowsByBrand.putIfAbsent(brand, () => []).add(i);
    }
    brands = rowsByBrand.keys.toList();
    final genericWords = {
      for (final m in meds)
        ...words(m['Generic Name With Strength']!).where(_isAlpha),
    };
    final companyWords = {
      for (final m in meds) ...words(m['Company']!).where(_isAlpha),
    };
    weakWords = {..._commonWords, ...genericWords, ...companyWords};
  }

  final DgdaRegister register;
  final rowsByBrand = <String, List<int>>{};
  late final List<String> brands;
  late final Set<String> weakWords;

  Row _row(int i) => register.medicines[i];

  bool _makerOnPack(Row row, Set<String> textWords) {
    final company = words(row['Company'] ?? '')
        .where((w) => w.length > 3 && !_commonWords.contains(w))
        .toList();
    return company.isNotEmpty && textWords.contains(company.first);
  }

  /// Points for other details of row [idx] that appear on the pack.
  int _support(int idx, Set<String> textWords, String textLower) {
    final row = _row(idx);
    var points = 0;
    if (_makerOnPack(row, textWords)) points += 3;
    final genericFull = row['Generic Name With Strength'] ?? '';
    final generic =
        words(genericFull).where((w) => _isAlpha(w) && w.length > 3).toList();
    if (generic.isNotEmpty && generic.every(textWords.contains)) points += 2;
    final strengths = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(genericFull)
        .map((m) => m.group(0)!)
        .toList();
    final found = strengths
        .where((s) => RegExp('(?<![\\d.])${RegExp.escape(s)}(?![\\d.])')
            .hasMatch(textLower))
        .length;
    if (strengths.isNotEmpty && found == strengths.length) {
      points += 2;
    } else if (found > 0) {
      points += 1;
    }
    final tradeWords = words(row['Trade Name'] ?? '');
    final trade = tradeWords.join(' ');
    if (tradeWords.length > 1 && words(textLower).join(' ').contains(trade)) {
      points += 2;
    }
    final form = (row['Dosage Form'] ?? '').toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (form.isNotEmpty && textWords.contains(form.last)) points += 1;
    // "Napa Rapid" is a different product from "Napa".
    points -= tradeWords
        .skip(1)
        .where((w) => _isAlpha(w) && !textWords.contains(w))
        .length;
    return points;
  }

  (int?, int) _bestRow(String brand, Set<String> textWords, String textLower,
      {bool requireMaker = false}) {
    var scored = [
      for (final i in rowsByBrand[brand]!) (_support(i, textWords, textLower), i),
    ];
    if (requireMaker) {
      scored = scored.where((s) => _makerOnPack(_row(s.$2), textWords)).toList();
      if (scored.isEmpty) return (null, 0);
    }
    // Highest support; on a tie the row listed first in the register.
    final best = _maxBy(scored, (s) => [s.$1, -s.$2]);
    return (best.$2, best.$1);
  }

  /// Finds and spell-checks the brand name in OCR [text]. With
  /// [expectedBrand] (from a DAR / MA lookup) only that brand is looked for.
  NameCheckResult check(String text, {String? expectedBrand}) {
    text = fixNumbers(text);
    final textLower = text.toLowerCase();
    final tokens = words(text);
    final textWords = tokens.toSet();

    if (expectedBrand != null && expectedBrand.isNotEmpty) {
      final brand = brandOf(expectedBrand);
      return _checkExpected(
          brand.isNotEmpty ? brand : expectedBrand.toLowerCase(),
          expectedBrand,
          tokens);
    }

    final candidates = <_Candidate>[];
    final nearWords = <(int, String, String)>[];
    for (var pos = 0; pos < tokens.length; pos++) {
      final token = tokens[pos];
      var matched = false;
      for (final variant in _exactVariants(token)) {
        if (variant.length < 3 || !rowsByBrand.containsKey(variant)) continue;
        final weak = weakWords.contains(variant);
        // A brand that is also an everyday / generic word counts only when
        // its maker is on the pack.
        final (idx, support) =
            _bestRow(variant, textWords, textLower, requireMaker: weak);
        if (idx == null) continue;
        candidates.add(
            _Candidate(idx, variant, token, exact, 100, support, pos, weak));
        matched = true;
        break;
      }
      if (!matched) {
        final vs = ocrVariants(token);
        final word = vs.isEmpty ? '' : vs.last;
        if (word.length >= 5 && !weakWords.contains(word)) {
          nearWords.add((pos, token, word));
        }
      }
    }

    if (candidates.isNotEmpty) {
      final best = _maxBy(candidates, (c) => [
            1, // all exact here
            c.weak ? 0 : 1,
            c.support,
            c.brand.length,
            -c.position,
          ]);
      return _result(best);
    }

    // A correctly spelled brand counts however little else was read, but
    // with too little text "no registered name" says nothing.
    if (_letter.allMatches(text).length < minLettersToJudge) {
      return NameCheckResult(unreadable);
    }

    // Look for a word one or two letters away from a brand whose maker or
    // generic is also on the pack.
    final suggestions = <String, int>{};
    for (final (pos, token, word) in nearWords) {
      final maxEdits = word.length < 7 ? 1 : 2;
      final matches = <(String, double)>[];
      for (final brand in brands) {
        if ((brand.length - word.length).abs() > maxEdits) continue;
        final score = ratio(word, brand);
        if (score < 75 || levenshtein(word, brand) > maxEdits) continue;
        matches.add((brand, score));
      }
      matches.sort((a, b) => b.$2.compareTo(a.$2));
      for (final (brand, score) in matches.take(5)) {
        final (idx, support) = _bestRow(brand, textWords, textLower);
        final name = _row(idx!)['Trade Name']!.trim();
        suggestions[name] = math.max(suggestions[name] ?? 0, score.round());
        if (support >= 2) {
          candidates.add(_Candidate(
              idx, brand, token, misspelled, score.round(), support, pos));
        }
      }
    }

    final ordered = (suggestions.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => e.key)
        .take(5)
        .toList();
    if (candidates.isNotEmpty) {
      final best = _maxBy(
          candidates, (c) => [c.support, c.similarity, -c.position]);
      return _result(best)..suggestions = ordered;
    }
    return NameCheckResult(notFound, suggestions: ordered);
  }

  /// Checks a name the user typed (not OCR text).
  NameCheckResult lookupName(String name) {
    final typed = words(name).join(' ');
    if (typed.isEmpty) return NameCheckResult(unreadable);
    String norm(int i) => words(_row(i)['Trade Name']!).join(' ');
    final meds = register.medicines;
    final brand = brandOf(name);
    int? idx;
    for (var i = 0; i < meds.length; i++) {
      if (norm(i) == typed) {
        idx = i;
        break;
      }
    }
    if (idx == null && brand == typed && rowsByBrand.containsKey(brand)) {
      final rows = rowsByBrand[brand]!;
      idx = rows.firstWhere((i) => norm(i) == brand, orElse: () => rows.first);
    }
    if (idx == null) {
      final query = brand.isNotEmpty ? brand : typed;
      final scored = [
        for (final b in brands) (b, ratio(query, b)),
      ]..removeWhere((s) => s.$2 < 70);
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return NameCheckResult(notFound,
          readName: name.trim(),
          suggestions:
              scored.take(5).map((s) => _displayName(s.$1)).toSet().toList());
    }
    return NameCheckResult(exact,
        readName: name.trim(),
        registeredName: _row(idx)['Trade Name']!.trim(),
        similarity: 100,
        rowIndex: idx);
  }

  /// How a brand is registered: "napa" -> "Napa" (not "Napa One").
  String _displayName(String brand) {
    final names = [
      for (final i in rowsByBrand[brand]!) _row(i)['Trade Name']!.trim(),
    ];
    return names.firstWhere((n) => words(n).join(' ') == brand,
        orElse: () => names.first);
  }

  NameCheckResult _checkExpected(
      String brand, String display, List<String> tokens) {
    var bestWord = '';
    var bestScore = 0;
    for (final token in tokens) {
      for (final variant in _exactVariants(token)) {
        if (variant == brand) {
          return NameCheckResult(exact,
              readName: token, registeredName: display, similarity: 100);
        }
        final score = ratio(variant, brand).round();
        if (score > bestScore) {
          bestWord = token;
          bestScore = score;
        }
      }
    }
    final maxEdits = brand.length < 7 ? 1 : 2;
    if (bestWord.isNotEmpty && brand.length >= 4) {
      final variant = ocrVariants(bestWord).last;
      final d = levenshtein(variant, brand);
      if (d > 0 && d <= maxEdits) {
        return NameCheckResult(misspelled,
            readName: bestWord, registeredName: display, similarity: bestScore);
      }
    }
    return NameCheckResult(notFound, registeredName: display);
  }

  NameCheckResult _result(_Candidate c) => NameCheckResult(c.status,
      readName: c.readAs,
      registeredName: _row(c.row)['Trade Name']!.trim(),
      similarity: c.similarity,
      rowIndex: c.row);
}
