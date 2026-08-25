import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_lock_service.dart';
import '../data/settings.dart';

/// Which stored PIN this screen is working with.
///
/// The two are deliberately separate secrets: the app PIN keeps other people
/// out of the app, the Kids PIN keeps the child *in* Kids mode. A child who
/// watched a parent unlock the phone must not thereby be able to leave Kids
/// mode.
enum _PinTarget { app, kids }

/// Ask for an existing PIN, or choose a new one.
enum _PinMode { verify, create }

/// Full-screen PIN pad: the app-lock gate, and the setup flow behind it.
///
/// Nothing here is a security boundary — [AppLockService] spells out why (the
/// hash lives in a plain preferences file, and this is a sideloaded personal
/// app). It is a nuisance lock: enough that handing someone your unlocked
/// phone does not hand them your watch history.
///
/// Callers never construct it. The four statics below are the whole surface,
/// so the rules about an unset PIN and an unescapable gate are decided in one
/// place instead of at each call site.
class AppLockPage extends StatefulWidget {
  // Positional, because an initialising formal cannot be a *named* private
  // parameter (`this._target` needs the name `_target`, which Dart forbids in
  // a named argument list) and spelling the assignment out instead trips
  // prefer_initializing_formals.
  const AppLockPage._(this._target, this._mode);

  final _PinTarget _target;
  final _PinMode _mode;

  /// Digits in a PIN. Four, matching the phone lock screen the user already
  /// knows, and short enough to auto-submit without a confirm button.
  static const pinLength = 4;

  /// Gates entry to the app. Resolves true once the user is in.
  ///
  /// The startup gate calls this; it returns false only when the user backed
  /// out, which cannot happen from the gate itself because the route refuses
  /// to pop.
  static Future<bool> unlock(BuildContext context) async {
    final settings = context.read<SettingsService>();
    // An enabled lock with no PIN set must not shut the owner out of their own
    // app. AppLockService.verify refuses an empty hash on purpose, so there
    // would be no way past this screen at all — treat it as already unlocked
    // and let Settings offer the setup.
    if (settings.appLockPinHash.isEmpty) return true;
    final unlocked = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const AppLockPage._(_PinTarget.app, _PinMode.verify),
      ),
    );
    return unlocked ?? false;
  }

  /// Sets or changes the app-lock PIN, asking twice.
  ///
  /// Returns when the flow closes, whether or not a PIN was stored — a
  /// cancelled setup is not an error. Callers that need to know read
  /// [SettingsService.appLockPinHash] afterwards, which is the value they
  /// would act on anyway.
  static Future<void> setUp(BuildContext context) =>
      _create(context, _PinTarget.app);

  /// The same flow for the PIN that guards leaving Kids mode.
  static Future<void> setUpKidsPin(BuildContext context) =>
      _create(context, _PinTarget.kids);

  /// Asks for the Kids PIN. True when it was entered correctly, or when no
  /// Kids PIN has been set — an unset guard must not block anything.
  static Future<bool> confirmKidsPin(BuildContext context) async {
    final settings = context.read<SettingsService>();
    if (settings.kidsPinHash.isEmpty) return true;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const AppLockPage._(_PinTarget.kids, _PinMode.verify),
      ),
    );
    return ok ?? false;
  }

  static Future<void> _create(BuildContext context, _PinTarget target) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AppLockPage._(target, _PinMode.create),
      ),
    );
  }

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  String _entered = '';

  /// The first of the two entries during setup. Empty means we are still
  /// collecting it.
  String _first = '';
  String _message = '';
  bool _biometricRunning = false;

  bool get _creating => widget._mode == _PinMode.create;
  bool get _confirming => _creating && _first.isNotEmpty;

  /// Only the startup gate is inescapable. A setup flow and the Kids-mode
  /// challenge are both things the user chose to open and may abandon.
  bool get _escapable => _creating || widget._target == _PinTarget.kids;

  bool get _offersBiometric =>
      !_creating &&
      widget._target == _PinTarget.app &&
      context.read<SettingsService>().appLockBiometric;

  @override
  void initState() {
    super.initState();
    // Prompt straight away rather than making the user tap the fingerprint
    // key first — that is how every other locked app behaves. Post-frame
    // because the platform prompt needs an attached view.
    if (_offersBiometric) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }
  }

  Future<void> _tryBiometric() async {
    if (_biometricRunning) return;
    setState(() => _biometricRunning = true);
    final ok = await const AppLockService().authenticateBiometric();
    if (!mounted) return;
    setState(() => _biometricRunning = false);
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    // Nothing is said on failure. The service collapses "cancelled", "no
    // sensor", "not enrolled" and "locked out" into a single false (it logs
    // which one), and the user's next move is the same for all of them: type
    // the PIN, which the pad already invites. An error line here would accuse
    // the user of a problem when they simply dismissed the sheet.
  }

  void _onDigit(String digit) {
    if (_entered.length >= AppLockPage.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += digit;
      _message = '';
    });
    if (_entered.length == AppLockPage.pinLength) {
      // Let the last dot paint before the screen reacts, otherwise the PIN
      // looks accepted a digit early and a wrong one seems to be rejected
      // before it was finished.
      Future<void>.delayed(const Duration(milliseconds: 120), _submit);
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _submit() {
    if (!mounted) return;
    final pin = _entered;
    setState(() => _entered = '');
    if (_creating) {
      _submitCreate(pin);
    } else {
      _submitVerify(pin);
    }
  }

  void _submitCreate(String pin) {
    if (_first.isEmpty) {
      setState(() {
        _first = pin;
        _message = '';
      });
      return;
    }
    if (_first != pin) {
      // The PIN is asked for twice precisely so a typo cannot lock the owner
      // out of their own app, so a mismatch restarts the whole setup rather
      // than quietly accepting either half of it.
      HapticFeedback.mediumImpact();
      setState(() {
        _first = '';
        _message = 'Those did not match. Start again.';
      });
      return;
    }

    final settings = context.read<SettingsService>();
    final hash = AppLockService.hashPin(pin);
    switch (widget._target) {
      case _PinTarget.app:
        settings.appLockPinHash = hash;
      case _PinTarget.kids:
        settings.kidsPinHash = hash;
    }
    Navigator.of(context).pop(true);
  }

  void _submitVerify(String pin) {
    final settings = context.read<SettingsService>();
    final hash = switch (widget._target) {
      _PinTarget.app => settings.appLockPinHash,
      _PinTarget.kids => settings.kidsPinHash,
    };
    if (AppLockService.verify(pin, hash)) {
      Navigator.of(context).pop(true);
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _message = 'Wrong PIN.');
  }

  String get _prompt {
    if (_creating) {
      return _confirming
          ? 'Re-enter the PIN to confirm'
          : widget._target == _PinTarget.kids
          ? 'Choose a PIN for Kids mode'
          : 'Choose a PIN';
    }
    return widget._target == _PinTarget.kids
        ? 'Enter the Kids PIN to leave Kids mode'
        : 'Enter your PIN';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // The startup gate is the whole point of the feature; a back press must
      // not walk around it.
      canPop: _escapable,
      child: Scaffold(
        appBar: _escapable
            ? AppBar(
                title: Text(
                  _creating
                      ? (widget._target == _PinTarget.kids
                            ? 'Kids PIN'
                            : 'App lock PIN')
                      : 'Kids mode',
                ),
              )
            : null,
        body: SafeArea(
          child: LayoutBuilder(
            // Scrolls rather than overflows: the pad plus the header is taller
            // than a phone in landscape, and this screen can appear there.
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 24),
                    Icon(
                      _creating ? Icons.pin_outlined : Icons.lock_outline,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _prompt,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _Dots(
                      filled: _entered.length,
                      length: AppLockPage.pinLength,
                      color: theme.colorScheme.primary,
                      empty: theme.colorScheme.onSurface.withValues(
                        alpha: 0.25,
                      ),
                    ),
                    SizedBox(
                      // Reserved whether or not there is a message, so the pad
                      // does not jump up and down as errors come and go.
                      height: 40,
                      child: Center(
                        child: Text(
                          _message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                    _keypad(theme),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _keypad(ThemeData theme) {
    const rows = <List<String>>[
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final digit in row) _digitKey(theme, digit)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _offersBiometric
                ? _iconKey(
                    theme,
                    Icons.fingerprint,
                    'Use biometrics',
                    _biometricRunning ? null : _tryBiometric,
                  )
                : const SizedBox(width: 84, height: 72),
            _digitKey(theme, '0'),
            _iconKey(
              theme,
              Icons.backspace_outlined,
              'Delete',
              _entered.isEmpty ? null : _onBackspace,
            ),
          ],
        ),
      ],
    );
  }

  Widget _digitKey(ThemeData theme, String digit) => SizedBox(
    width: 84,
    height: 72,
    child: InkResponse(
      radius: 40,
      onTap: () => _onDigit(digit),
      child: Center(
        child: Text(
          digit,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ),
  );

  Widget _iconKey(
    ThemeData theme,
    IconData icon,
    String tooltip,
    VoidCallback? onTap,
  ) => SizedBox(
    width: 84,
    height: 72,
    child: InkResponse(
      radius: 40,
      onTap: onTap,
      child: Center(
        child: Icon(
          icon,
          semanticLabel: tooltip,
          color: onTap == null
              ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
              : theme.colorScheme.onSurface,
        ),
      ),
    ),
  );
}

class _Dots extends StatelessWidget {
  const _Dots({
    required this.filled,
    required this.length,
    required this.color,
    required this.empty,
  });

  final int filled;
  final int length;
  final Color color;
  final Color empty;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < length; i++)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < filled ? color : Colors.transparent,
            border: Border.all(color: i < filled ? color : empty, width: 2),
          ),
        ),
    ],
  );
}
