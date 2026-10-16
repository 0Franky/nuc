import 'package:flutter/widgets.dart';

/// Immutable snapshot of a file transfer shown in the File Drop screen.
/// Updates are produced with [copyWith] instead of mutating shared state.
@immutable
class TransferItem {
  final String fileId;
  final String name;
  final String size;
  final double progress;
  final String speed;
  final String eta;
  final String peer;
  final String status;
  final IconData icon;
  final Color color;

  const TransferItem({
    required this.fileId,
    required this.name,
    required this.size,
    required this.progress,
    required this.speed,
    required this.eta,
    required this.peer,
    required this.status,
    required this.icon,
    required this.color,
  });

  TransferItem copyWith({
    String? fileId,
    String? name,
    String? size,
    double? progress,
    String? speed,
    String? eta,
    String? peer,
    String? status,
    IconData? icon,
    Color? color,
  }) {
    return TransferItem(
      fileId: fileId ?? this.fileId,
      name: name ?? this.name,
      size: size ?? this.size,
      progress: progress ?? this.progress,
      speed: speed ?? this.speed,
      eta: eta ?? this.eta,
      peer: peer ?? this.peer,
      status: status ?? this.status,
      icon: icon ?? this.icon,
      color: color ?? this.color,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransferItem &&
          other.fileId == fileId &&
          other.name == name &&
          other.size == size &&
          other.progress == progress &&
          other.speed == speed &&
          other.eta == eta &&
          other.peer == peer &&
          other.status == status &&
          other.icon == icon &&
          other.color == color;

  @override
  int get hashCode => Object.hash(fileId, name, size, progress, speed, eta, peer, status, icon, color);
}
