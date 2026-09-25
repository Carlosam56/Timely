part of '../main.dart';

/// Shown once, right after account creation, so the app doesn't start on an
/// arbitrary default. Reads/writes the same [appThemeMode] / [appAccentColor]
/// notifiers as the "Erscheinungsbild" section in Settings, so nothing extra
/// needs to be wired up for the choice to persist.
class AppearancePickerPage extends StatelessWidget {
  const AppearancePickerPage({super.key, required this.onDone});

  final VoidCallback onDone;

  static const _accentColors = [
    Color(0xFF8B5CF6),
    Color(0xFF3B82F6),
    Color(0xFF06B6D4),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFEC4899),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              const Icon(Icons.palette_outlined, size: 48),
              const SizedBox(height: 20),
              const Text(
                'Erscheinungsbild',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Du kannst das später jederzeit in den Einstellungen ändern.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 36),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: appThemeMode,
                builder: (context, mode, _) {
                  return SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Hell'),
                        icon: Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dunkel'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (value) => appThemeMode.value = value.first,
                  );
                },
              ),
              const SizedBox(height: 32),
              const Text(
                'Akzentfarbe',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 14),
              ValueListenableBuilder<Color>(
                valueListenable: appAccentColor,
                builder: (context, selected, _) {
                  return Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final color in _accentColors)
                        InkWell(
                          onTap: () => appAccentColor.value = color,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected.toARGB32() == color.toARGB32()
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            child: selected.toARGB32() == color.toARGB32()
                                ? const Icon(Icons.check, size: 18, color: Colors.white)
                                : null,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const Spacer(),
              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: onDone,
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Weiter'),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
