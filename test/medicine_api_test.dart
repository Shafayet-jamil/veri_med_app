import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:veri_med_app/services/medicine_api.dart';

void main() {
  late List<http.BaseRequest> requests;

  MedicineApi apiWith({String apiKey = '', int status = 200, Object? body}) {
    requests = [];
    return MedicineApi(
      apiKey: apiKey,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(body ?? {'medicines': <Object>[]}),
          status,
        );
      }),
    );
  }

  Future<void> callEveryEndpoint(MedicineApi api) async {
    await api.lookupLicense('186-0479-006');
    await api.getMedicineNames();
    await api.checkInteractions(['Warfarin', 'Aspirin']);
    await api.scanMedicine(
      XFile.fromData(utf8.encode('img'), name: 'label.jpg'),
    );
  }

  test('sends the API key on every request when one is set', () async {
    final api = apiWith(apiKey: 'test-key-123');
    await callEveryEndpoint(api);

    expect(requests, hasLength(4));
    for (final request in requests) {
      expect(request.headers['X-API-Key'], 'test-key-123',
          reason: request.url.path);
    }
  });

  test('sends no API key header when none is set', () async {
    final api = apiWith();
    await callEveryEndpoint(api);

    for (final request in requests) {
      expect(request.headers.containsKey('X-API-Key'), isFalse,
          reason: request.url.path);
    }
  });

  test('shows the server error message on failure', () async {
    final api = apiWith(
      status: 429,
      body: {'error': 'Too many scans. Please wait a minute and try again.'},
    );

    expect(
      () => api.lookupLicense('186-0479-006'),
      throwsA(isA<MedicineApiException>().having(
        (e) => e.message,
        'message',
        'Too many scans. Please wait a minute and try again.',
      )),
    );
  });
}
