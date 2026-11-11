import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../archive/presentation/providers/archive_provider.dart';
import '../restore/presentation/providers/restore_provider.dart';

/// One photo or file shared into the app. [path] is already a private copy
/// under `<temp>/share_in/<uuid>/`; [count] is how many items the share held
/// (only the first is taken).
class SharedItem {
  const SharedItem({
    required this.path,
    required this.name,
    required this.isImage,
    required this.count,
  });

  final String path;
  final String? name;
  final bool isImage;
  final int count;
}

/// `PlatformException.code` the native side uses when a share arrived but
/// could not be read.
const shareUnreadableCode = 'share_unreadable';

/// Wraps the `com.nfcarchiver/share_in` channel.
class ShareInbox {
  ShareInbox([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('com.nfcarchiver/share_in');

  final MethodChannel _channel;

  /// The waiting item, or null. Throws [PlatformException] (code
  /// [shareUnreadableCode]) when a share arrived but could not be read.
  Future<SharedItem?> take() async {
    final Map<String, Object?>? m;
    try {
      m = await _channel.invokeMapMethod<String, Object?>('take');
    } on MissingPluginException {
      return null; // A platform without share-in (desktop, tests).
    }
    if (m == null) return null;
    return SharedItem(
      path: m['path']! as String,
      name: m['name'] as String?,
      isImage: m['isImage'] as bool? ?? false,
      count: (m['count'] as num?)?.toInt() ?? 1,
    );
  }

  /// Calls [onShareAvailable] when native says a share arrived while running.
  void listen(void Function() onShareAvailable) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShareAvailable') onShareAvailable();
    });
  }

  void stopListening() => _channel.setMethodCallHandler(null);
}

final shareInboxProvider = Provider<ShareInbox>((_) => ShareInbox());

/// Replacing this archive state would throw away tags already written, or
/// cut off a write session in progress (even on its first tag).
bool archiveWorkInProgress(ArchiveState s) => switch (s) {
      ArchiveReady(:final writtenChunks) => writtenChunks.isNotEmpty,
      ArchiveWriting() => true,
      _ => false,
    };

/// Leaving this restore state would interrupt collected or running work.
bool restoreWorkInProgress(RestoreState s) => switch (s) {
      RestoreScanning(:final sessions) => sessions.isNotEmpty,
      RestoreReady() || RestoreInProgress() => true,
      _ => false,
    };
