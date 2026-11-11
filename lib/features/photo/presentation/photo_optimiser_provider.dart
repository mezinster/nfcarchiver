import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/nfar_format.dart';
import '../../../core/log/logger.dart';
import '../../../core/services/archive_sizing.dart';
import '../../../core/providers/dev_options_provider.dart';
import '../../archive/presentation/providers/archive_provider.dart';
import '../../nfc/domain/tag_type_availability.dart';
import '../../nfc/presentation/providers/reader_provider.dart';
import '../data/photo_temp.dart';
import '../data/platform_jpeg_session.dart';
import '../domain/optimised_file_name.dart';
import '../domain/photo_fit.dart';

/// A photo waiting for the optimiser. [name] is null when the source gave none.
class PendingPhoto {
  const PendingPhoto({required this.path, this.name, required this.size});

  final String path;
  final String? name;
  final int size;
}

/// Set by whoever hands a photo to the optimiser, before
/// `context.go('/archive/optimise')`.
final pendingPhotoProvider = StateProvider<PendingPhoto?>((_) => null);

/// Opens an encoder session for a file; overridable in tests.
final jpegSessionOpenerProvider =
    Provider<Future<JpegEncoderSession> Function(String path)>(
        (_) => PlatformJpegSession.open);

enum PhotoMode { auto, manual }

enum PhotoError { none, decodeFailed }

/// Stepper and slider changes wait this long before re-fitting.
const photoRefitDebounce = Duration(milliseconds: 250);

class PhotoOptimiserState {
  const PhotoOptimiserState({
    required this.tagType,
    required this.tags,
    required this.cap,
    this.mode = PhotoMode.auto,
    this.manualSide,
    this.manualQuality,
    this.result,
    this.needed,
    this.width = 0,
    this.height = 0,
    this.busy = true,
    this.error = PhotoError.none,
  });

  final NfcTagType tagType;
  final int tags;

  /// The tag count the original file needs; the stepper's upper bound.
  final int cap;
  final PhotoMode mode;
  final int? manualSide;
  final int? manualQuality;
  final PhotoFitResult? result;

  /// Smallest tag count whose budget fits [result].
  final int? needed;

  /// Source dimensions after orientation; 0 until the session is open.
  final int width;
  final int height;
  final bool busy;
  final PhotoError error;

  int get longestSide => math.max(width, height);

  bool get canContinue => !busy && error == PhotoError.none && result != null;

  PhotoOptimiserState copyWith({
    NfcTagType? tagType,
    int? tags,
    int? cap,
    PhotoMode? mode,
    int? manualSide,
    int? manualQuality,
    PhotoFitResult? result,
    bool clearResult = false,
    int? needed,
    int? width,
    int? height,
    bool? busy,
    PhotoError? error,
  }) =>
      PhotoOptimiserState(
        tagType: tagType ?? this.tagType,
        tags: tags ?? this.tags,
        cap: cap ?? this.cap,
        mode: mode ?? this.mode,
        manualSide: manualSide ?? this.manualSide,
        manualQuality: manualQuality ?? this.manualQuality,
        result: clearResult ? null : result ?? this.result,
        needed: clearResult ? null : needed ?? this.needed,
        width: width ?? this.width,
        height: height ?? this.height,
        busy: busy ?? this.busy,
        error: error ?? this.error,
      );
}

/// Thrown inside a fit that a newer request has superseded.
class _Stale implements Exception {
  const _Stale();
}

/// Aborts a running fit as soon as it is no longer the latest request, so a
/// superseded search stops at its next encode instead of running to the end.
class _GuardedSession implements JpegEncoderSession {
  _GuardedSession(this._inner, this._current);

  final JpegEncoderSession _inner;
  final bool Function() _current;

  @override
  int get width => _inner.width;
  @override
  int get height => _inner.height;

  @override
  Future<Uint8List> encode({required int maxSide, required int quality}) async {
    if (!_current()) throw const _Stale();
    final bytes = await _inner.encode(maxSide: maxSide, quality: quality);
    if (!_current()) throw const _Stale();
    return bytes;
  }

  @override
  Future<void> close() async {} // the notifier owns the real session
}

class PhotoOptimiserNotifier extends StateNotifier<PhotoOptimiserState> {
  PhotoOptimiserNotifier(this._ref, this._photo)
      : _outName = optimisedFileName(
            _photo.name == null ? null : p.basename(_photo.name!),
            DateTime.now()),
        super(PhotoOptimiserState(
          tagType: _ref.read(selectedTagTypeProvider),
          tags: 1,
          cap: _capFor(_photo, _ref.read(selectedTagTypeProvider)),
        )) {
    _open();
  }

  final Ref _ref;
  final PendingPhoto _photo;
  final String _outName;

  JpegEncoderSession? _session;
  bool _disposed = false;
  Timer? _debounce;
  bool _holding = false;
  int _gen = 0;
  Future<void> _chain = Future<void>.value();
  final Map<(NfcTagType, int), PhotoFitResult> _autoFits = {};

  /// The name the optimised file is archived under.
  String get outputName => _outName;

  static String _originalName(PendingPhoto photo) =>
      photo.name ?? p.basename(photo.path);

  /// The original's tag count, held to [1, NfarLimits.maxChunks]: an archive
  /// cannot carry more chunks than the header's uint16 count can say.
  static int _capFor(PendingPhoto photo, NfcTagType type) => math.min(
      NfarLimits.maxChunks,
      math.max(
          1,
          tagsNeeded(
              archivedByteCount(
                  dataSize: photo.size,
                  fileName: _originalName(photo),
                  encrypt: true),
              type)));

  int _tagsFor(int bytes, NfcTagType type) => tagsNeeded(
      archivedByteCount(dataSize: bytes, fileName: _outName, encrypt: true),
      type);

  Future<void> _open() async {
    try {
      final s = await _ref.read(jpegSessionOpenerProvider)(_photo.path);
      if (_disposed) {
        _closeQuietly(s);
        return;
      }
      _session = s;
      final longest = math.max(s.width, s.height);
      final probe =
          await s.encode(maxSide: math.min(640, longest), quality: 70);
      if (_disposed) return;
      state = state.copyWith(
        width: s.width,
        height: s.height,
        tags: _tagsFor(probe.length, state.tagType).clamp(1, state.cap),
      );
      _schedule(now: true);
    } catch (e, st) {
      if (!_disposed) _fail(e, st);
    }
  }

  void setTags(int n) {
    final tags = n.clamp(1, state.cap);
    if (tags == state.tags) return;
    state = state.copyWith(tags: tags);
    _schedule();
  }

  /// A held stepper: [setTags] moves the count on screen but fits nothing
  /// until [endHold], so a long hold costs one fit, not one per step.
  void beginHold() {
    _holding = true;
    _debounce?.cancel();
    _gen++; // a fit already under way is stale now
    if (_session != null && state.error == PhotoError.none) {
      state = state.copyWith(busy: true);
    }
  }

  /// Safe after dispose: `RepeatButton` calls it from a microtask, which can
  /// land after the screen (and this notifier) went away.
  void endHold() {
    if (_disposed || !_holding) return;
    _holding = false;
    _schedule();
  }

  void setTagType(NfcTagType type) {
    if (type == state.tagType) return;
    final cap = _capFor(_photo, type);
    state = state.copyWith(
        tagType: type, cap: cap, tags: math.min(state.tags, cap));
    _schedule(now: true);
  }

  /// Moves off a tag type the reader or the 4K switch no longer offers, by
  /// the rule Archive settings applies ([replacementTagType]).
  void normaliseTagType({
    required bool mifareAvailable,
    required bool mifare4kEnabled,
  }) {
    final replacement = replacementTagType(state.tagType,
        mifareAvailable: mifareAvailable, mifare4kEnabled: mifare4kEnabled);
    if (replacement != null) setTagType(replacement);
  }

  /// Switches to manual mode, starting from the current result's settings.
  void setManual({int? side, int? quality}) {
    if (state.error != PhotoError.none || _session == null) return;
    state = state.copyWith(
      mode: PhotoMode.manual,
      manualSide: side ??
          (state.mode == PhotoMode.manual ? state.manualSide : null) ??
          state.result?.maxSide ??
          state.longestSide,
      manualQuality: quality ??
          (state.mode == PhotoMode.manual ? state.manualQuality : null) ??
          state.result?.quality ??
          70,
    );
    _schedule(now: quality == null);
  }

  void backToAuto() {
    if (state.mode == PhotoMode.auto) return;
    state = state.copyWith(mode: PhotoMode.auto);
    _schedule(now: true);
  }

  /// Writes the optimised JPEG to the temp folder and hands it to the archive
  /// flow, with GZIP off (it only adds bytes to a JPEG).
  Future<void> continueWithResult() async {
    final r = state.result;
    if (!state.canContinue || r == null) return;
    final temp = await _ref.read(photoTempDirProvider)();
    final dir = Directory(p.join(temp.path, photoOptimiserDirName));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, _outName));
    await file.writeAsBytes(r.bytes, flush: true);
    _ref.read(archiveProvider.notifier).selectFile(
          filePath: file.path,
          fileName: _outName,
          fileSize: r.bytes.length,
        );
    _ref.read(compressionEnabledProvider.notifier).state = false;
    _ref.read(selectedTagTypeProvider.notifier).state = state.tagType;
  }

  /// "Continue with N tags", offered when the result does not fit: moves the
  /// count to [PhotoOptimiserState.needed], re-fits at once (auto may find a
  /// better image that still fits; manual keeps its side and quality) and, if
  /// that fits, continues as [continueWithResult]. The count may pass the cap
  /// for this, never the NFAR maximum. Returns whether it continued.
  Future<bool> continueAtNeeded() async {
    final st = state;
    final needed = st.needed;
    final r = st.result;
    if (_disposed || !st.canContinue || r == null || r.fits || needed == null) {
      return false;
    }
    // Held to [1, max(cap, needed)] and the NFAR maximum; needed is never
    // above max(cap, needed), so only 1 and the maximum can bite.
    final tags = math.max(1, math.min(needed, NfarLimits.maxChunks));
    state = state.copyWith(tags: tags);
    if (_session == null) return false;
    final gen = ++_gen;
    _debounce?.cancel();
    state = state.copyWith(busy: true);
    await (_chain = _chain.then((_) => _fit(gen)));
    if (!_isCurrent(gen)) return false;
    final after = state;
    if (!after.canContinue || after.tags != tags || !after.result!.fits) {
      return false;
    }
    await continueWithResult();
    return true;
  }

  /// Archives the original file untouched; compression is left as it was.
  void skip() {
    _ref.read(archiveProvider.notifier).selectFile(
          filePath: _photo.path,
          fileName: _originalName(_photo),
          fileSize: _photo.size,
        );
    _ref.read(selectedTagTypeProvider.notifier).state = state.tagType;
  }

  void _schedule({bool now = false}) {
    if (_session == null || state.error != PhotoError.none) return;
    final gen = ++_gen;
    _debounce?.cancel();
    state = state.copyWith(busy: true);
    if (_holding) return; // endHold schedules the fit
    void run() => _chain = _chain.then((_) => _fit(gen));
    if (now) {
      run();
    } else {
      _debounce = Timer(photoRefitDebounce, run);
    }
  }

  bool _isCurrent(int gen) => gen == _gen && !_disposed;

  Future<void> _fit(int gen) async {
    final s = _session;
    if (s == null || !_isCurrent(gen)) return;
    final st = state;
    final budget =
        photoByteBudget(tags: st.tags, tagType: st.tagType, fileName: _outName);
    final guarded = _GuardedSession(s, () => _isCurrent(gen));
    try {
      final PhotoFitResult r;
      if (st.mode == PhotoMode.auto) {
        r = _autoFits[(st.tagType, st.tags)] ??=
            await fitToBudget(guarded, budget);
      } else {
        r = await encodeManual(guarded,
            maxSide: st.manualSide!,
            quality: st.manualQuality!,
            budgetBytes: budget);
      }
      if (!_isCurrent(gen)) return;
      state = state.copyWith(
        result: r,
        needed: _tagsFor(r.bytes.length, st.tagType),
        busy: false,
      );
    } on _Stale {
      return;
    } catch (e, stack) {
      if (_isCurrent(gen)) _fail(e, stack);
    }
  }

  void _fail(Object e, StackTrace st) {
    log.report('photo', 'photo optimiser failed', e, st);
    state = state.copyWith(
        error: PhotoError.decodeFailed, busy: false, clearResult: true);
  }

  void _closeQuietly(JpegEncoderSession s) {
    s.close().catchError((Object e) {
      log.warn('photo', 'encoder session close failed',
          {'error': '${e.runtimeType}'});
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    final s = _session;
    if (s != null) _closeQuietly(s);
    super.dispose();
  }
}

final photoOptimiserProvider = StateNotifierProvider.autoDispose<
    PhotoOptimiserNotifier, PhotoOptimiserState>((ref) {
  final photo = ref.read(pendingPhotoProvider);
  if (photo == null) throw StateError('no pending photo');
  final notifier = PhotoOptimiserNotifier(ref, photo);

  // The same normalisation Archive settings applies: fitting for a medium the
  // reader (or the 4K switch) no longer offers would promise a tag count that
  // settings then breaks by swapping the medium. Re-applied whenever either
  // input changes while the screen is open.
  void normalise() {
    final mifare = ref.read(mifareClassicAvailableProvider);
    if (!mifare.hasValue) return;
    notifier.normaliseTagType(
        mifareAvailable: mifare.requireValue,
        mifare4kEnabled: ref.read(mifare4kEnabledProvider));
  }

  ref.listen(mifareClassicAvailableProvider, (_, __) => normalise());
  ref.listen(mifare4kEnabledProvider, (_, __) => normalise());
  normalise();
  return notifier;
});
