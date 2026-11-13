import 'package:image_picker/image_picker.dart';

import 'medicine_api.dart';
import 'offline_medicine_service.dart';

/// What the screens need from a medicine checker. Implemented by
/// [OfflineMedicineService] (everything on the phone, the default) and by
/// [MedicineApi] (the optional Python server).
abstract class MedicineService {
  Future<Map<String, dynamic>> scanMedicine(XFile image);
  Future<Map<String, dynamic>> lookupLicense(String licenseNumber);
  Future<Map<String, dynamic>> lookupName(String name);
  Future<List<Map<String, dynamic>>> getMedicineNames();
  Future<Map<String, dynamic>> checkInteractions(List<String> medicineNames);

  static MedicineService? _default;

  /// The server when the app was built with `MEDICHECKER_API_URL`, otherwise
  /// the on-device checker.
  static MedicineService get defaultService => _default ??=
      MedicineApi.configuredUrl.isNotEmpty
          ? MedicineApi()
          : OfflineMedicineService();
}
