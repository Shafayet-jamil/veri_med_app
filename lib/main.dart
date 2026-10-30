import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'services/medicine_api.dart';

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
      home: const MediCheckerHomePage(),
    );
  }
}

class MediCheckerHomePage extends StatefulWidget {
  const MediCheckerHomePage({super.key});

  @override
  State<MediCheckerHomePage> createState() => _MediCheckerHomePageState();
}

class _MediCheckerHomePageState extends State<MediCheckerHomePage> {
  final _api = MedicineApi();
  final _picker = ImagePicker();
  final _licenseController = TextEditingController();

  XFile? _image;
  Uint8List? _imageBytes;
  Map<String, dynamic>? _result;
  String? _error;
  bool _isLoading = false;

  @override
  void dispose() {
    _licenseController.dispose();
    super.dispose();
  }

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
    await _runRequest(() => _api.scanMedicine(image));
  }

  Future<void> _lookupLicense() async {
    final licenseNumber = _licenseController.text.trim();
    if (licenseNumber.isEmpty) {
      setState(() => _error = 'Enter a DAR / MA license number.');
      return;
    }
    await _runRequest(() => _api.lookupLicense(licenseNumber));
  }

  Future<void> _runRequest(
    Future<Map<String, dynamic>> Function() request,
  ) async {
    setState(() {
      _isLoading = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await request();
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
                  'Check a medicine',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Scan the package to extract its details, or look it up '
                  'using its DAR / MA number.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                _buildScanCard(context),
                const SizedBox(height: 18),
                _buildLicenseCard(context),
                if (_isLoading) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 8),
                  const Center(child: Text('Contacting MediChecker server…')),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 18),
                  _buildError(error),
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

  Widget _buildScanCard(BuildContext context) {
    return _SectionCard(
      title: 'Scan medicine package',
      subtitle:
          'Take a clear photo of the label or select one from your device.',
      icon: Icons.document_scanner_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_image case final image?) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _imageBytes!,
                height: 220,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const SizedBox(
                  height: 120,
                  child: Center(child: Text('Preview unavailable')),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              image.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ] else ...[
            Container(
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF4F2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo_outlined, size: 34),
                  SizedBox(height: 8),
                  Text('Your medicine photo will appear here'),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _isLoading
                    ? null
                    : () => _selectImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Take photo'),
              ),
              OutlinedButton.icon(
                onPressed: _isLoading
                    ? null
                    : () => _selectImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose photo'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isLoading ? null : _scanImage,
            icon: const Icon(Icons.search),
            label: const Text('Scan and find details'),
          ),
        ],
      ),
    );
  }

  Widget _buildLicenseCard(BuildContext context) {
    return _SectionCard(
      title: 'Look up by DAR / MA number',
      subtitle: 'Enter the registration number printed on the medicine.',
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
          FilledButton.tonalIcon(
            onPressed: _isLoading ? null : _lookupLicense,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('Find license details'),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
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
    final fields = <(String, String)>[
      ('DAR / MA number', _value('dar_number')),
      ('Brand / trade name', _value('brand_name')),
      ('Generic name', _value('generic_name')),
      ('Manufacturer', _value('manufacturer')),
      ('Strength', _value('strength')),
      ('Dosage form', _value('dosage_form')),
      ('Registration status', _value('status')),
      ('Validity', _value('validity')),
      ('Manufacturer license (biological)', _value('mfg_license_biological')),
      (
        'Manufacturer license (non-biological)',
        _value('mfg_license_non_biological'),
      ),
      ('Address', _value('description')),
    ].where((field) => field.$2.isNotEmpty).toList();
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
                Icon(
                  notFound ? Icons.search_off : Icons.fact_check_outlined,
                  color: notFound
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    notFound ? 'No matching record' : 'Medicine details',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final (label, value) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 155,
                        child: Text(
                          label,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (extractedText.isNotEmpty) ...[
              const Divider(height: 28),
              Text(
                'Text extracted from image',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SelectableText(extractedText),
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
