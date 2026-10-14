import 'dart:typed_data';
import 'song_model.dart';

class AlbumModel {
  final String title;
  final String artist;
  final int? albumId;
  final List<SongModel> songs;
  Uint8List? artworkBytes;

  AlbumModel({
    required this.title,
    required this.artist,
    this.albumId,
    required this.songs,
    this.artworkBytes,
  });

  int get trackCount => songs.length;
}
