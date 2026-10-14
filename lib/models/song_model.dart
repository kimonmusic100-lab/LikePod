import 'dart:typed_data';

class SongModel {
  final int id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String uri;
  final int? albumId;
  final Uint8List? artworkBytes;

  const SongModel({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.uri,
    this.albumId,
    this.artworkBytes,
  });

  String get formattedDuration {
    final totalSeconds = durationMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
