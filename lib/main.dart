import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'screens/interaction_checker_screen.dart';
import 'services/medicine_api.dart';
import 'widgets/section_card.dart';
import 'widgets/verification_badge.dart';

void main() {
  runApp(const MediCheckerApp());
}

class MediCheckerApp extends StatelessWidget {
  const MediCheckerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF087F73);
    return MaterialApp(
      title: 'MediChecker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: color),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE2E8E6)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: color, width: 1.5),
          ),
        ),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;

  final _pages = const <Widget>[
    ScanScreen(),
    LookupScreen(),
    InteractionCheckerScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        backgroundColor: Colors.white,
        indicatorColor: Theme.of(context).colorScheme.primaryContainer,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'Scan',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Lookup',
          ),
          NavigationDestination(
            icon: Icon(Icons.compare_arrows_outlined),
            selectedIcon: Icon(Icons.compare_arrows),
            label: 'Interactions',
          ),
        ],
      ),
    );
  }
}

// ─── Scan Screen ─────────────────────────────────────────────────────────────

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _api = MedicineApi();
  final _picker = ImagePicker();

  XFile? _image;
  Uint8List? _imageBytes;
  Map<String, dynamic>? _result;
  String? _error;
  bool _isLoading = false;

  Future<void> _selectImage(ImageSource source) async {
    try {
      final image = await _picker.pickImage(
        source: source,
        imageQuality: 90,
        maxWidth: 2400,
      );
      if (!mounted || image == null) return;
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = image;
        _imageBytes = bytes;
        _result = null;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not select the image: $error');
    }
  }

  Future<void> _scanImage() async {
    final image = _image;
    if (image == null) {
      setState(() => _error = 'Choose or take a medicine photo first.');
      return;
    }
    setState(() {
      _isLoading = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await _api.scanMedicine(image);
      if (!mounted) return;
      setState(() => _result = result);
    } on MedicineApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Request failed: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.medication_outlined),
            SizedBox(width: 10),
            Text('MediChecker'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  'Scan medicine',
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Take a photo of the medicine package to verify its authenticity against the DGDA database.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 24),
                _buildCameraCard(context),
                if (_isLoading) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Scanning and verifying...',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 18),
                  _ErrorBanner(message: error),
                ],
                if (_result case final result?) ...[
                  const SizedBox(height: 18),
                  if (result['verification'] case final Map<String, dynamic> v)
                    VerificationBadge(verification: v),
                  const SizedBox(height: 14),
                  MedicineResultCard(result: result),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraCard(BuildContext context) {
    return SectionCard(
      title: 'Scan medicine package',
      subtitle: 'Take a clear photo of the label or select from gallery.',
      icon: Icons.document_scanner_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_image != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _imageBytes!,
                height: 220,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 120,
                  child: Center(child: Text('Preview unavailable')),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _image!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ] else ...[
            Container(
              height: 140,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF4F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFCCDDD9),
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo_outlined,
                      size: 38,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 10),
                  Text(
                    'Your medicine photo will appear here',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _isLoading ? null : () => _selectImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Camera'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isLoading
                      ? null
                      : () => _selectImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isLoading || _image == null ? null : _scanImage,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Scan & Verify Authenticity'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Lookup Screen ───────────────────────────────────────────────────────────

class LookupScreen extends StatefulWidget {
  const LookupScreen({super.key});

  @override
  State<LookupScreen> createState() => _LookupScreenState();
}

class _LookupScreenState extends State<LookupScreen> {
  final _api = MedicineApi();
  final _licenseController = TextEditingController();

  Map<String, dynamic>? _result;
  String? _error;
  bool _isLoading = false;

  @override
  void dispose() {
    _licenseController.dispose();
    super.dispose();
  }

  Future<void> _lookupLicense() async {
    final licenseNumber = _licenseController.text.trim();
    if (licenseNumber.isEmpty) {
      setState(() => _error = 'Enter a DAR / MA license number.');
      return;
    }
    setState(() {
      _isLoading = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await _api.lookupLicense(licenseNumber);
      if (!mounted) return;
      setState(() => _result = result);
    } on MedicineApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Request failed: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.confirmation_number_outlined),
            SizedBox(width: 10),
            Text('License Lookup'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  'Look up medicine',
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter the DAR / MA registration number printed on the medicine package.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 24),
                SectionCard(
                  title: 'DAR / MA number lookup',
                  subtitle:
                      'Find registration details by license number.',
                  icon: Icons.confirmation_number_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _licenseController,
                        enabled: !_isLoading,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _lookupLicense(),
                        decoration: const InputDecoration(
                          labelText: 'DAR / MA license number',
                          hintText: 'e.g. 481-0003-034',
                          prefixIcon: Icon(Icons.numbers),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _isLoading ? null : _lookupLicense,
                        icon: const Icon(Icons.search),
                        label: const Text('Find License Details'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isLoading) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Looking up license...',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 18),
                  _ErrorBanner(message: error),
                ],
                if (_result case final result?) ...[
                  const SizedBox(height: 18),
                  MedicineResultCard(result: result),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shared Widgets ──────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class MedicineResultCard extends StatelessWidget {
  const MedicineResultCard({super.key, required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final extractedText = result['extracted_text']?.toString().trim() ?? '';
    final fields = <(String, IconData, String)>[
      (
        'DAR / MA number',
        Icons.confirmation_number_outlined,
        _value('dar_number')
      ),
      ('Brand / trade name', Icons.label_outlined, _value('brand_name')),
      (
        'Generic name',
        Icons.medical_information_outlined,
        _value('generic_name')
      ),
      ('Manufacturer', Icons.factory_outlined, _value('manufacturer')),
      ('Strength', Icons.science_outlined, _value('strength')),
      ('Dosage form', Icons.medication_outlined, _value('dosage_form')),
      (
        'Registration status',
        Icons.verified_outlined,
        _value('status')
      ),
      ('Validity', Icons.calendar_today_outlined, _value('validity')),
      (
        'MFG license (biological)',
        Icons.biotech_outlined,
        _value('mfg_license_biological')
      ),
      (
        'MFG license (non-biological)',
        Icons.precision_manufacturing_outlined,
        _value('mfg_license_non_biological')
      ),
      ('Address', Icons.location_on_outlined, _value('description')),
    ].where((field) => field.$3.isNotEmpty).toList();
    final notFound = result['match_found'] == false;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE2E8E6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: notFound
                        ? Theme.of(context)
                            .colorScheme
                            .errorContainer
                        : Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    notFound ? Icons.search_off : Icons.fact_check_outlined,
                    color: notFound
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notFound ? 'No matching record' : 'Medicine Details',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (!notFound)
                        Text(
                          'From DGDA registration database',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final (label, icon, value) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 130,
                        child: Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          value,
                          style: const TextStyle(
                              fontWeight: FontWeight.w500, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (extractedText.isNotEmpty) ...[
              const Divider(height: 28),
              Row(
                children: [
                  Icon(Icons.text_snippet_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    'Extracted text from image',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  extractedText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _value(String key) {
    final value = result[key]?.toString().trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'nan') return '';
    return value;
  }
}
