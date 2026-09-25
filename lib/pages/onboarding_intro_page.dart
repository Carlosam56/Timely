part of '../main.dart';

class _IntroSlide {
  final IconData icon;
  final String title;
  final String body;

  const _IntroSlide({required this.icon, required this.title, required this.body});
}

const _introSlides = [
  _IntroSlide(
    icon: Icons.link,
    title: 'Verbinde WebUntis',
    body:
        'Timely holt deinen Stundenplan direkt von WebUntis - mit deiner Schule '
        'und deinen gewohnten Zugangsdaten. Deine Zugangsdaten gehen dabei nur '
        'an WebUntis, nie an Timely-Server.',
  ),
  _IntroSlide(
    icon: Icons.calendar_month_outlined,
    title: 'Dein Stundenplan',
    body:
        'Sieh deinen Stundenplan übersichtlich auf einen Blick, inklusive '
        'Vertretungen und Ausfällen. Timely kann Fehler enthalten - prüfe im '
        'Zweifel immer deinen offiziellen Stundenplan in WebUntis.',
  ),
  _IntroSlide(
    icon: Icons.groups_outlined,
    title: 'Bleib verbunden',
    body:
        'Füge Freunde hinzu, bildet Gruppen und seht (mit Erlaubnis) gegenseitig '
        'eure Stundenpläne - praktisch, um Freistunden oder Lerntreffen zu planen.',
  ),
];

/// Shown once before account creation to explain what Timely does.
/// Also reachable any time from Settings > Über Timely > "Einführung
/// erneut ansehen" with [isReplay] set to true, in which case it is a
/// normal pushed route that just pops when finished instead of handing
/// control back to [OnboardingGate].
class IntroPage extends StatefulWidget {
  const IntroPage({super.key, this.isReplay = false, this.onFinished});

  final bool isReplay;
  final VoidCallback? onFinished;

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (widget.isReplay) {
      Navigator.of(context).pop();
      return;
    }
    await _markOnboardingSeen();
    widget.onFinished?.call();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isLast = _page == _introSlides.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12, top: 4),
                child: TextButton(
                  onPressed: _finish,
                  child: Text(widget.isReplay ? 'Schließen' : 'Überspringen'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _introSlides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final slide = _introSlides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(slide.icon, size: 44, color: accent),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          slide.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          slide.body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < _introSlides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? accent : accent.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              child: SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: () {
                    if (isLast) {
                      _finish();
                    } else {
                      _controller.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    isLast ? (widget.isReplay ? 'Fertig' : "Los geht's") : 'Weiter',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
