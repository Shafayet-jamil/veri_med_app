import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

const _apiBaseUrl = String.fromEnvironment(
  'MEDICHECKER_API_URL',
  defaultValue: 'http://10.0.2.2:5000',
);

class MedicineApi {
  MedicineApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, dynamic>> scanMedicine(XFile image) async {
    final request = http.MultipartRequest('POST', _endpoint('/scan-medicine'))
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          await image.readAsBytes(),
          filename: image.name,
        ),
      );
    final streamedResponse = await _client
        .send(request)
        .timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamedResponse);
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> lookupLicense(String licenseNumber) async {
    final uri = _endpoint('/verify-license')
        .replace(queryParameters: {'dar_number': licenseNumber});
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 30));
    return _decodeResponse(response);
  }

  Future<List<Map<String, dynamic>>> getMedicineNames() async {
    final response = await _client
        .get(_endpoint('/medicine-names'))
        .timeout(const Duration(seconds: 30));
    final decoded = _decodeResponse(response);
    final medicines = decoded['medicines'];
    if (medicines is List) {
      return medicines.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> checkInteractions(
      List<String> medicineNames) async {
    final response = await _client
        .post(
          _endpoint('/check-interactions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'medicines': medicineNames}),
        )
        .timeout(const Duration(seconds: 30));
    return _decodeResponse(response);
  }

  Uri _endpoint(String path) {
    final base = Uri.parse(_apiBaseUrl);
    return base.resolve(path);
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw MedicineApiException(
        'The server returned an invalid response '
        '(HTTP ${response.statusCode}).',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw MedicineApiException(
        'The server response has an unexpected format.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          decoded['error']?.toString() ??
          decoded['description']?.toString() ??
          'Request failed (HTTP ${response.statusCode}).';
      throw MedicineApiException(message);
    }
    return decoded;
  }
}

class MedicineApiException implements Exception {
  const MedicineApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
