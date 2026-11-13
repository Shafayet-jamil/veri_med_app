import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../offline/offline_checker.dart';
import 'medicine_api.dart' show MedicineApiException;
import 'medicine_service.dart';

/// Reads the text lines in a photo, in reading order.
typedef TextReader = Future<List<String>> Function(XFile image);

const medicineCsvAsset = 'mediCheker/excelFile/medicine_information_DAR_MA.csv';
const companyCsvAsset =
    'mediCheker/excelFile/Company Info functionalOrNonFunctional.csv';
const interactionsCsvAsset = 'mediCheker/excelFile/drug_interactions.csv';

/// Checks medicines entirely on the phone: Google ML Kit reads the photo,
/// and the DGDA register ships inside the app. No server or internet needed.
class OfflineMedicineService implements MedicineService {
  OfflineMedicineService({TextReader? textReader, AssetBundle? bundle})
      : _readText = textReader ?? readTextWithMlKit,
        _bundle = bundle ?? rootBundle;

  final TextReader _readText;
  final AssetBundle _bundle;
  Future<OfflineChecker>? _checker;

  /// The register is parsed once, in a background isolate, so the app
  /// stays responsive while the 41,000-row CSV loads.
  Future<OfflineChecker> get checker => _checker ??= _load();

  Future<OfflineChecker> _load() async {
    final medicine = await _bundle.loadString(medicineCsvAsset, cache: false);
    final company = await _bundle.loadString(companyCsvAsset, cache: false);
    final interactions = await _bundle.loadString(interactionsCsvAsset);
    OfflineChecker build() => OfflineChecker(
        medicineCsv: medicine,
        companyCsv: company,
        interactionsCsv: interactions);
    if (kIsWeb) return build();
    return Isolate.run(build);
  }

  @override
  Future<Map<String, dynamic>> scanMedicine(XFile image) async {
    final checker = await this.checker;
    final List<String> lines;
    try {
      lines = cleanOcrLines(await _readText(image));
    } on MedicineApiException {
      rethrow;
    } catch (error) {
      throw MedicineApiException('Could not read text from the photo: $error');
    }
    return {
      'extracted_text': lines.join(' | '),
      ...checker.identifyAndVerify(lines.join(' ')),
    };
  }

  @override
  Future<Map<String, dynamic>> lookupLicense(String licenseNumber) async {
    final result = (await checker).verifyLicense(licenseNumber.trim());
    if (result == null) {
      throw MedicineApiException(
          'No license records found for DAR number: ${licenseNumber.trim()}');
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> lookupName(String name) async =>
      (await checker).verifyName(name);

  @override
  Future<List<Map<String, dynamic>>> getMedicineNames() async =>
      (await checker).medicineNameList;

  @override
  Future<Map<String, dynamic>> checkInteractions(
          List<String> medicineNames) async =>
      (await checker).checkInteractions(medicineNames);
}

TextRecognizer? _recognizer;

/// On-device OCR with Google ML Kit (Latin script). The model is bundled in
/// the app, so it works offline.
Future<List<String>> readTextWithMlKit(XFile image) async {
  if (kIsWeb) {
    throw const MedicineApiException(
        'Scanning works in the Android or iOS app, not in a browser.');
  }
  final recognizer =
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
  final recognized =
      await recognizer.processImage(InputImage.fromFilePath(image.path));
  final lines = [
    for (final block in recognized.blocks)
      for (final line in block.lines) line,
  ];
  return sortLinesByPosition([
    for (final l in lines)
      (l.text, l.boundingBox.top, l.boundingBox.left, l.boundingBox.height),
  ]);
}

/// Sorts (text, top, left, height) lines top-to-bottom, then left-to-right
/// within a row, like the Python OCR step did.
List<String> sortLinesByPosition(List<(String, double, double, double)> lines) {
  if (lines.isEmpty) return [];
  final heights = lines.map((l) => l.$4).toList()..sort();
  final median = heights[heights.length ~/ 2];
  final threshold = median * 0.5 > 10 ? median * 0.5 : 10.0;

  final sorted = List.of(lines)
    ..sort((a, b) {
      final c = a.$2.compareTo(b.$2);
      return c != 0 ? c : a.$3.compareTo(b.$3);
    });
  final rows = <List<(String, double, double, double)>>[];
  for (final line in sorted) {
    if (rows.isNotEmpty && (line.$2 - rows.last.first.$2).abs() <= threshold) {
      rows.last.add(line);
    } else {
      rows.add([line]);
    }
  }
  return [
    for (final row in rows)
      for (final l in row..sort((a, b) => a.$3.compareTo(b.$3))) l.$1,
  ];
}
