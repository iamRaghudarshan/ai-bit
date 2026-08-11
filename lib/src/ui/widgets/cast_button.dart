import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The Cast button: iOS's system output-route picker, hosted as a platform
/// view.
///
/// It covers Apple TV and AirPlay receivers, which is what a Cast button does
/// on an iPhone. Only Apple's own `AVRoutePickerView` can open the picker, and
/// only it knows whether a route is currently connected, so this wraps that
/// view rather than drawing a button and trying to drive it.
///
/// Chromecast is not supported: it needs the Google Cast SDK and a receiver
/// app id. On anything other than iOS this renders nothing rather than a
/// button that would do nothing.
class CastButton extends StatelessWidget {
  const CastButton({super.key, this.size = 26});

  final double size;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    return SizedBox(
      width: size,
      height: size,
      // The picker draws its own glyph and handles its own taps, so nothing
      // above it should intercept them.
      child: const UiKitView(viewType: 'ai.bit/route_picker'),
    );
  }
}

/// Chip-shaped wrapper so the Cast button sits in the watch page's action row
/// alongside Speed, Quality and the rest.
class CastChip extends StatelessWidget {
  const CastChip({super.key});

  @override
  Widget build(BuildContext context) {
    if (!CastButton.isSupported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The platform view paints white, which is invisible on a light
              // chip, so it sits on a dark disc of its own.
              DecoratedBox(
                decoration: const BoxDecoration(
                  color: AppColors.darkElevated,
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: CastButton(size: 20),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Cast',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
