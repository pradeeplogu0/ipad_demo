import 'dart:math';

import 'package:material_ui/material_ui.dart';

void main() => runApp(const IpadDemoApp());

class IpadDemoApp extends StatelessWidget {
  const IpadDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iPad Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const TapBoxPage(),
    );
  }
}

class TapBoxPage extends StatefulWidget {
  const TapBoxPage({super.key});

  @override
  State<TapBoxPage> createState() => _TapBoxPageState();
}

class _TapBoxPageState extends State<TapBoxPage> {
  static const _startColor = Color(0xFF5C6BC0);
  final _random = Random();

  int _count = 0;
  Color _color = _startColor;
  bool _pressed = false;

  Color _randomColor() {
    // HSV keeps colours vivid and pleasant instead of muddy.
    final hue = _random.nextDouble() * 360;
    final saturation = 0.55 + _random.nextDouble() * 0.35;
    final value = 0.65 + _random.nextDouble() * 0.3;
    return HSVColor.fromAHSV(1, hue, saturation, value).toColor();
  }

  void _tap() {
    setState(() {
      _count++;
      _color = _randomColor();
    });
  }

  void _reset() {
    setState(() {
      _count = 0;
      _color = _startColor;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onBox = ThemeData.estimateBrightnessForColor(_color) == Brightness.dark
        ? Colors.white
        : Colors.black87;

    return Scaffold(
      appBar: AppBar(
        title: const Text('iPad Demo'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton.filledTonal(
              tooltip: 'Reset',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _count == 0 ? null : _reset,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Size the box from the shorter side so it fits nicely in
            // both portrait and landscape on phones and iPads.
            final shortest = constraints.biggest.shortestSide;
            final boxSize = (shortest * 0.62).clamp(180.0, 560.0);

            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTapDown: (_) => setState(() => _pressed = true),
                    onTapUp: (_) => setState(() => _pressed = false),
                    onTapCancel: () => setState(() => _pressed = false),
                    onTap: _tap,
                    child: AnimatedScale(
                      scale: _pressed ? 0.95 : 1.0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeInOutCubic,
                        width: boxSize,
                        height: boxSize,
                        decoration: BoxDecoration(
                          color: _color,
                          borderRadius: BorderRadius.circular(boxSize * 0.14),
                          boxShadow: [
                            BoxShadow(
                              color: _color.withValues(alpha: 0.45),
                              blurRadius: boxSize * 0.12,
                              offset: Offset(0, boxSize * 0.04),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              transitionBuilder: (child, animation) =>
                                  ScaleTransition(
                                scale: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                              child: Text(
                                '$_count',
                                key: ValueKey(_count),
                                style: theme.textTheme.displayLarge?.copyWith(
                                  color: onBox,
                                  fontWeight: FontWeight.w700,
                                  fontSize: boxSize * 0.3,
                                ),
                              ),
                            ),
                            Text(
                              _count == 1 ? 'tap' : 'taps',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: onBox.withValues(alpha: 0.85),
                                fontSize: boxSize * 0.07,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: boxSize * 0.12),
                  Text(
                    'Tap the box to change its colour',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
