import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'medicine_service.dart';

/// Set at build time to use the Python server instead of the on-device
/// checker, e.g. `--dart-define=MEDICHECKER_API_URL=http://10.0.2.2:5000`.
const _configuredUrl = String.fromEnvironment('MEDICHECKER_API_URL');
const _apiBaseUrl =
    _configuredUrl == '' ? 'http://10.0.2.2:5000' : _configuredUrl;

/// Must match the server's MEDICHECKER_API_KEY when the server sets one.
const _apiKey = String.fromEnvironment('MEDICHECKER_API_KEY');

/// Client for the optional Python server in `mediCheker/`.
class MedicineApi implements MedicineService {
  static const configuredUrl = _configuredUrl;

  MedicineApi({http.Client? client, String apiKey = _apiKey})
      : _client = client ?? http.Client(),
        _headers = {if (apiKey.isNotEmpty) 'X-API-Key': apiKey};

  final http.Client _client;
  final Map<String, String> _headers;

  @override
  Future<Map<String, dynamic>> scanMedicine(XFile image) async {
    final request = http.MultipartRequest('POST', _endpoint('/scan-medicine'))
      ..headers.addAll(_headers)
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

  @override
  Future<Map<String, dynamic>> lookupLicense(String licenseNumber) async {
    final uri = _endpoint('/verify-license')
        .replace(queryParameters: {'dar_number': licenseNumber});
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    return _decodeResponse(response);
  }

  /// Checks a typed medicine (brand) name against the DGDA register. A name
  /// that is not registered comes back with `match_found: false` and the
  /// closest registered spellings, not as an error.
  @override
  Future<Map<String, dynamic>> lookupName(String name) async {
    final uri =
        _endpoint('/verify-name').replace(queryParameters: {'name': name});
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic> && decoded['match_found'] == false) {
          return decoded;
        }
      } on FormatException {
        // Fall through to the normal error handling.
      }
    }
    return _decodeResponse(response);
  }

  @override
  Future<List<Map<String, dynamic>>> getMedicineNames() async {
    final response = await _client
        .get(_endpoint('/medicine-names'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    final decoded = _decodeResponse(response);
    final medicines = decoded['medicines'];
    if (medicines is List) {
      return medicines.cast<Map<String, dynamic>>();
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> checkInteractions(
      List<String> medicineNames) async {
    final response = await _client
        .post(
          _endpoint('/check-interactions'),
          headers: {..._headers, 'Content-Type': 'application/json'},
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
