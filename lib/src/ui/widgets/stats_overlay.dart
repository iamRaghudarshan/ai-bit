import 'package:flutter/material.dart';

/// YouTube's "Stats for nerds", as far as this player can report it.
///
/// Deliberately plain: a fixed-width monospace block in the corner, dismissed
/// by tapping it, so it never gets in the way of the controls underneath.
class StatsOverlay extends StatelessWidget {
  const StatsOverlay({super.key, required this.stats, required this.onClose});

  final Map<String, String> stats;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: GestureDetector(
          onTap: onClose,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in stats.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${entry.key}: ${entry.value}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          height: 1.3,
                          fontFamily: 'monospace',
                          fontFamilyFallback: ['Courier'],
                        ),
                      ),
                    ),
                  const SizedBox(height: 2),
                  const Text(
                    'tap to close',
                    style: TextStyle(color: Colors.white38, fontSize: 9),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
