import 'package:equatable/equatable.dart';

import '../constants/nfar_format.dart';

/// Information about a detected NFC tag.
class NfcTagInfo extends Equatable {
  /// Creates NFC tag info.
  const NfcTagInfo({
    required this.identifier,
    required this.capacity,
    this.isWritable = true,
    this.isNdefCapable = true,
    this.tagType,
    this.technologies = const [],
  });

  /// Tag unique identifier (UID)
  final String identifier;

  /// Total capacity in bytes
  final int capacity;

  /// Whether the tag is writable
  final bool isWritable;

  /// Whether the tag supports NDEF
  final bool isNdefCapable;

  /// Detected tag type (if recognized)
  final NfcTagType? tagType;

  /// List of supported NFC technologies
  final List<String> technologies;

  /// Maximum payload size for NFAR chunks on this tag
  int get maxPayloadSize {
    // NDEF overhead is approximately 5-10 bytes
    const ndefOverhead = 10;
    final available = capacity - ndefOverhead;
    return available - NfarHeaderSize.total;
  }

  /// Whether this tag can store NFAR data
  bool get canStoreNfar => isWritable && isNdefCapable && maxPayloadSize > 0;

  /// Determine tag type from capacity if not already set.
  NfcTagType get effectiveTagType {
    if (tagType != null) return tagType!;

    // Try to match by capacity
    for (final type in NfcTagType.values) {
      if (type == NfcTagType.custom) continue;
      if (type.capacity == capacity) return type;
    }

    return NfcTagType.custom;
  }

  /// Short description of the tag
  String get description {
    if (tagType != null) {
      return '${tagType!.name} ($capacity bytes)';
    }
    return 'NFC Tag ($capacity bytes)';
  }

  /// Create a copy with updated fields.
  NfcTagInfo copyWith({
    String? identifier,
    int? capacity,
    bool? isWritable,
    bool? isNdefCapable,
    NfcTagType? tagType,
    List<String>? technologies,
  }) {
    return NfcTagInfo(
      identifier: identifier ?? this.identifier,
      capacity: capacity ?? this.capacity,
      isWritable: isWritable ?? this.isWritable,
      isNdefCapable: isNdefCapable ?? this.isNdefCapable,
      tagType: tagType ?? this.tagType,
      technologies: technologies ?? this.technologies,
    );
  }

  @override
  List<Object?> get props => [
        identifier,
        capacity,
        isWritable,
        isNdefCapable,
        tagType,
        technologies,
      ];

  @override
  String toString() => 'NfcTagInfo('
      'id: ${identifier.substring(0, identifier.length.clamp(0, 8))}..., '
      'capacity: $capacity, '
      'writable: $isWritable)';
}

/// Result of reading an NFC tag.
sealed class NfcReadResult {
  const NfcReadResult();
}

/// Successfully read NFAR chunk from tag.
class NfcReadSuccess extends NfcReadResult {
  const NfcReadSuccess({
    required this.tagInfo,
    required this.data,
  });

  final NfcTagInfo tagInfo;
  final List<int> data;
}

/// Tag was read but contains no NFAR data.
class NfcReadEmpty extends NfcReadResult {
  const NfcReadEmpty({required this.tagInfo});

  final NfcTagInfo tagInfo;
}

/// Tag contains data but it's not valid NFAR format.
class NfcReadInvalidFormat extends NfcReadResult {
  const NfcReadInvalidFormat({
    required this.tagInfo,
    required this.reason,
  });

  final NfcTagInfo tagInfo;
  final String reason;
}

/// Error reading from tag.
class NfcReadError extends NfcReadResult {
  const NfcReadError({
    required this.message,
    this.tagInfo,
  });

  final String message;
  final NfcTagInfo? tagInfo;
}

/// Result of writing to an NFC tag.
sealed class NfcWriteResult {
  const NfcWriteResult();
}

/// Successfully wrote data to tag.
class NfcWriteSuccess extends NfcWriteResult {
  const NfcWriteSuccess({
    required this.tagInfo,
    required this.bytesWritten,
  });

  final NfcTagInfo tagInfo;
  final int bytesWritten;
}

/// Tag doesn't have enough capacity.
class NfcWriteInsufficientCapacity extends NfcWriteResult {
  const NfcWriteInsufficientCapacity({
    required this.tagInfo,
    required this.required,
    required this.available,
  });

  final NfcTagInfo tagInfo;
  final int required;
  final int available;
}

/// Tag is not writable.
class NfcWriteNotWritable extends NfcWriteResult {
  const NfcWriteNotWritable({required this.tagInfo});

  final NfcTagInfo tagInfo;
}

/// Error writing to tag.
class NfcWriteError extends NfcWriteResult {
  const NfcWriteError({
    required this.message,
    this.tagInfo,
  });

  final String message;
  final NfcTagInfo? tagInfo;
}
