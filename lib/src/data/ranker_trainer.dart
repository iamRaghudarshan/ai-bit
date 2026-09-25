import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'db.dart';
import 'recommender.dart';
import 'settings.dart';

/// Owns the ranker's learned weights: loads them, trains them, stores them.
///
/// The pure half of this lives in [RankerWeights], which knows how to predict
/// and how to take a gradient step. This is the part with a database and a
/// preferences file behind it — deliberately separated, because the arithmetic
/// is the part worth testing and it should not need either.
///
/// ## When training happens
///
/// Once per feed load, off the critical path. A training pass is a few hundred
/// multiplications over at most a few hundred rows; it is not worth a
/// background isolate and it is not worth making the feed wait for it either,
/// so it is started and not awaited.
///
/// ## Why it cannot make the feed worse
///
/// [RankerWeights.blend] never lets learning own more than half the answer,
/// every weight is clamped, and nothing learned is applied until
/// [RankerWeights.minExamplesToApply] observations exist. A single-user model
/// sees a handful of examples a day, and a linear model given a handful of
/// examples will cheerfully conclude something absurd — these are the guards
/// against that, and they are the reason this can be switched on by default.
class RankerTrainer {
  RankerTrainer({
    required AppDatabase database,
    required SettingsService settings,
  })  : _db = database,
        _config = settings;

  final AppDatabase _db;
  final SettingsService _config;

  /// Cached so a feed load does not re-parse the stored JSON every time.
  RankerWeights? _cached;

  /// The weights ranking should use right now.
  ///
  /// Falls back to [RankerWeights.prior] whenever anything is missing,
  /// unreadable or below the evidence threshold — a corrupted preference must
  /// degrade to the hand-tuned defaults, never to zeros, which would rank
  /// everything equally and look exactly like the feature being broken.
  RankerWeights get weights {
    if (!_config.adaptiveRanking) return RankerWeights.prior;
    final learned = _cached ??= _read();
    return RankerWeights.blend(learned, _config.rankerExamplesSeen);
  }

  RankerWeights _read() {
    final raw = _config.rankerWeightsJson;
    if (raw.isEmpty) return RankerWeights.prior;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return RankerWeights.prior;
      return RankerWeights.fromMap(decoded.cast<String, Object?>());
    } catch (e) {
      debugPrint('AI BIT: stored ranker weights unreadable, using defaults - $e');
      return RankerWeights.prior;
    }
  }

  /// Trains on whatever has settled since the last pass.
  ///
  /// Fire-and-forget by design: the feed must never wait on this, and a
  /// failure means "the ranker keeps the weights it had", which costs nothing.
  /// Logged rather than swallowed, because a training loop that quietly stops
  /// running is indistinguishable from one that was never wired up.
  Future<void> train() async {
    if (!_config.adaptiveRanking) return;
    try {
      final examples = await _db.takeRankingExamples();
      if (examples.isEmpty) return;

      final updated = (_cached ??= _read()).trainedOn(examples);
      _cached = updated;
      _config.rankerWeightsJson = jsonEncode(updated.toMap());
      _config.rankerExamplesSeen =
          _config.rankerExamplesSeen + examples.length;

      final opened = examples.where((e) => e.opened).length;
      debugPrint(
        'AI BIT: ranker trained on ${examples.length} examples '
        '($opened opened), ${_config.rankerExamplesSeen} lifetime',
      );
    } catch (e) {
      debugPrint('AI BIT: ranker training failed - $e');
    }
  }

  /// Forgets everything learned and goes back to the hand-tuned weights.
  ///
  /// Exposed because a model fitted to a borrowed phone, or to an afternoon
  /// that was not representative, is a thing a user should be able to undo
  /// without clearing their whole history.
  Future<void> reset() async {
    _cached = null;
    _config.rankerWeightsJson = '';
    _config.rankerExamplesSeen = 0;
    await _db.clearRankerLearning();
  }

  /// How much of the ranking is currently learned rather than hand-tuned,
  /// 0..1 — for the settings screen, so the feature can say what it is doing
  /// instead of being an unexplained switch.
  double get learnedShare {
    if (!_config.adaptiveRanking) return 0;
    final seen = _config.rankerExamplesSeen;
    if (seen < RankerWeights.minExamplesToApply) return 0;
    final progress = ((seen - RankerWeights.minExamplesToApply) /
            (RankerWeights.examplesForFullTrust -
                RankerWeights.minExamplesToApply))
        .clamp(0.0, 1.0);
    return RankerWeights.maxLearnedShare * progress;
  }

  int get examplesSeen => _config.rankerExamplesSeen;
}
