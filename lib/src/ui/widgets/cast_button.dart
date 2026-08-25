import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'cast_sheet.dart';

/// The Cast button, which is two different things depending on the platform.
///
/// **iOS**: Apple's system output-route picker, hosted as a platform view. It
/// covers Apple TV and AirPlay receivers, which is what a Cast button means on
/// an iPhone. Only Apple's own `AVRoutePickerView` can open the picker, and
/// only it knows whether a route is currently connected, so this wraps that
/// view rather than drawing a button and trying to drive it. The view handles
/// its own taps — nothing may sit above it intercepting them, which is why the
/// iOS branch has no `onTap` of its own.
///
/// **Everywhere else**: a cast icon that opens [showCastSheet], which finds
/// DLNA/UPnP renderers on the LAN and hands one of them the stream URL. That is
/// the Chromecast replacement — the Cast SDK was ruled out because it needs a
/// registered receiver application id.
///
/// iOS deliberately does not get the DLNA sheet: iOS 14+ gates the SSDP
/// multicast discovery needs behind `com.apple.developer.networking.multicast`,
/// so the scan would come back empty on the one platform that already has a
/// working picker.
class CastButton extends StatelessWidget {
  const CastButton({super.key, this.size = 26});

  final double size;

  /// True where the Cast button is Apple's route picker rather than ours.
  static bool get isAirPlay =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether to offer casting at all.
  ///
  /// Every native platform now has a route to a TV — AirPlay on iOS, DLNA
  /// elsewhere — so this is only false on web, where there is no player and no
  /// UDP socket to discover with.
  static bool get isSupported => !kIsWeb;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    if (isAirPlay) {
      return SizedBox(
        width: size,
        height: size,
        child: const UiKitView(viewType: 'ai.bit/route_picker'),
      );
    }
    // Sized to `size` rather than left to IconButton, whose 48dp minimum
    // overflows the 24dp leading slot the watch page's overflow sheet gives it.
    return SizedBox(
      width: size,
      height: size,
      child: InkResponse(
        radius: size,
        onTap: () => showCastSheet(context),
        child: Icon(Icons.cast, size: size),
      ),
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
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (CastButton.isAirPlay)
              // The platform view paints white, which is invisible on a light
              // chip, so it sits on a dark disc of its own.
              const DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.darkElevated,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(3),
                  child: CastButton(size: 20),
                ),
              )
            else
              const Icon(Icons.cast, size: 20),
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
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      // On iOS the embedded picker owns its taps, so the chip must not wrap
      // itself in a gesture detector that would swallow them first.
      child: CastButton.isAirPlay
          ? chip
          : InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => showCastSheet(context),
              child: chip,
            ),
    );
  }
}
