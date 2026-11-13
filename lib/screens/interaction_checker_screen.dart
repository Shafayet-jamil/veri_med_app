import 'package:flutter/material.dart';
import '../services/medicine_api.dart';
import '../services/medicine_service.dart';

class InteractionCheckerScreen extends StatefulWidget {
  const InteractionCheckerScreen({super.key, this.api});

  final MedicineService? api;

  @override
  State<InteractionCheckerScreen> createState() =>
      _InteractionCheckerScreenState();
}

class _InteractionCheckerScreenState extends State<InteractionCheckerScreen> {
  late final _api = widget.api ?? MedicineService.defaultService;
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _allMedicines = [];
  List<Map<String, dynamic>> _filteredMedicines = [];
  final List<String> _selectedMedicines = [];
  List<Map<String, dynamic>> _interactions = [];
  List<Map<String, dynamic>> _sources = [];

  bool _isLoadingNames = true;
  bool _isChecking = false;
  bool _hasChecked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMedicineNames();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMedicineNames() async {
    try {
      final names = await _api.getMedicineNames();
      if (!mounted) return;
      setState(() {
        _allMedicines = names;
        _filteredMedicines = [];
        _isLoadingNames = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load medicine list: $e';
        _isLoadingNames = false;
      });
    }
  }

  void _filterMedicines(String query) {
    if (query.length < 2) {
      setState(() => _filteredMedicines = []);
      return;
    }
    final q = query.toLowerCase();
    setState(() {
      _filteredMedicines = _allMedicines.where((m) {
        final trade = (m['trade_name'] ?? '').toString().toLowerCase();
        final generic = (m['generic_name'] ?? '').toString().toLowerCase();
        return trade.contains(q) || generic.contains(q);
      }).take(20).toList();
    });
  }

  void _addMedicine(Map<String, dynamic> medicine) {
    final name = medicine['generic_name']?.toString() ?? '';
    if (name.isEmpty || _selectedMedicines.contains(name)) return;
    setState(() {
      _selectedMedicines.add(name);
      _searchController.clear();
      _filteredMedicines = [];
      _hasChecked = false;
      _interactions = [];
    });
  }

  void _removeMedicine(int index) {
    setState(() {
      _selectedMedicines.removeAt(index);
      _hasChecked = false;
      _interactions = [];
    });
  }

  Future<void> _checkInteractions() async {
    if (_selectedMedicines.length < 2) {
      setState(() => _error = 'Select at least 2 medicines to check.');
      return;
    }

    setState(() {
      _isChecking = true;
      _error = null;
      _interactions = [];
    });

    try {
      final result = await _api.checkInteractions(_selectedMedicines);
      if (!mounted) return;
      final interactions = result['interactions'];
      final sources = result['sources'];
      setState(() {
        _interactions =
            interactions is List ? interactions.cast<Map<String, dynamic>>() : [];
        _sources = sources is List ? sources.cast<Map<String, dynamic>>() : [];
        _hasChecked = true;
      });
    } on MedicineApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Check failed: $e');
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'severe':
        return const Color(0xFFD32F2F);
      case 'moderate':
        return const Color(0xFFF57C00);
      case 'mild':
        return const Color(0xFF388E3C);
      default:
        return const Color(0xFF757575);
    }
  }

  IconData _severityIcon(String severity) {
    switch (severity.toLowerCase()) {
      case 'severe':
        return Icons.dangerous_outlined;
      case 'moderate':
        return Icons.warning_amber_outlined;
      case 'mild':
        return Icons.info_outline;
      default:
        return Icons.help_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.compare_arrows),
            SizedBox(width: 10),
            Text('Drug Interactions'),
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
                  'Check drug interactions',
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Select two or more medicines to check for known interactions between them.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 24),
                _buildSearchCard(context),
                const SizedBox(height: 18),
                if (_selectedMedicines.isNotEmpty) ...[
                  _buildSelectedCard(context),
                  const SizedBox(height: 18),
                ],
                if (_isChecking) ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 8),
                  const Center(child: Text('Checking interactions...')),
                ],
                if (_error case final error?) ...[
                  _buildError(error),
                  const SizedBox(height: 18),
                ],
                if (_hasChecked && !_isChecking) _buildResults(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchCard(BuildContext context) {
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
                Icon(Icons.search,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Search and add medicines',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Type a medicine name to search. Tap a result to add it.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            if (_isLoadingNames)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              TextField(
                controller: _searchController,
                onChanged: _filterMedicines,
                decoration: const InputDecoration(
                  labelText: 'Medicine name',
                  hintText: 'e.g. Omeprazole, Napa, Aspirin',
                  prefixIcon: Icon(Icons.medication_outlined),
                ),
              ),
              if (_filteredMedicines.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE2E8E6)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _filteredMedicines.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final m = _filteredMedicines[index];
                      final trade = m['trade_name'] ?? '';
                      final generic = m['generic_name'] ?? '';
                      final alreadySelected =
                          _selectedMedicines.contains(generic);
                      return ListTile(
                        dense: true,
                        enabled: !alreadySelected,
                        leading: Icon(
                          alreadySelected
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
                          color: alreadySelected
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(trade),
                        subtitle: Text(generic,
                            style: Theme.of(context).textTheme.bodySmall),
                        onTap: alreadySelected ? null : () => _addMedicine(m),
                      );
                    },
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedCard(BuildContext context) {
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
                Icon(Icons.medication_liquid_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Selected medicines (${_selectedMedicines.length})',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _selectedMedicines.length; i++)
                  Chip(
                    label: Text(_selectedMedicines[i]),
                    deleteIcon: const Icon(Icons.close, size: 18),
                    onDeleted: () => _removeMedicine(i),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _isChecking || _selectedMedicines.length < 2
                        ? null
                        : _checkInteractions,
                icon: const Icon(Icons.compare_arrows),
                label: const Text('Check interactions'),
              ),
            ),
            if (_selectedMedicines.length < 2) ...[
              const SizedBox(height: 8),
              Text(
                'Add at least 2 medicines to check interactions.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_interactions.isEmpty) {
      return Card(
        elevation: 0,
        color: const Color(0xFFE8F5E9),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFC8E6C9)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Color(0xFF388E3C), size: 32),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No known interactions found',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _usesDdinter
                          ? 'None of the selected medicines are listed together '
                              'in the interaction databases checked. This does '
                              'not prove the combination is safe. Always confirm '
                              'with a doctor or pharmacist.'
                          : 'None of the selected medicines are listed together '
                              'in our interaction database. This database covers '
                              'a limited set of common drugs, so it does not '
                              'prove the combination is safe. Always confirm '
                              'with a doctor or pharmacist.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    _buildSources(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_interactions.length} interaction${_interactions.length > 1 ? 's' : ''} found',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        for (final interaction in _interactions) ...[
          _buildInteractionCard(context, interaction),
          const SizedBox(height: 12),
        ],
        _buildSources(context),
      ],
    );
  }

  bool get _usesDdinter => _sources.any((s) => s['name'] == 'DDInter');

  /// Credits the data sources (DDInter's license requires attribution).
  Widget _buildSources(BuildContext context) {
    if (_sources.isEmpty) return const SizedBox.shrink();
    final text = _sources.map((s) {
      final license = s['license']?.toString() ?? '';
      final url = s['url']?.toString() ?? '';
      return [
        s['name'],
        if (license.isNotEmpty) '($license)',
        if (url.isNotEmpty) url,
      ].join(' ');
    }).join('; ');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Data sources: $text',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  Widget _buildInteractionCard(
      BuildContext context, Map<String, dynamic> interaction) {
    final severity = interaction['severity']?.toString() ?? 'unknown';
    final color = _severityColor(severity);
    final icon = _severityIcon(severity);

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${interaction['drug_a']} + ${interaction['drug_b']}',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          severity.toLowerCase() == 'unknown'
                              ? 'SEVERITY UNKNOWN'
                              : severity.toUpperCase(),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              interaction['effect']?.toString() ?? '',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if ((interaction['source']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Source: ${interaction['source']}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            if ((interaction['recommendation']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        interaction['recommendation'].toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
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
