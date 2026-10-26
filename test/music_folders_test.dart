import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/music_service.dart';

void main() {
  test('pathUnder matches on path boundaries only', () {
    const folder = '/storage/emulated/0/Music';
    expect(MusicService.pathUnder('/storage/emulated/0/Music/a.mp3', folder), isTrue);
    expect(MusicService.pathUnder('/storage/emulated/0/Music/sub/b.flac', folder), isTrue);
    expect(MusicService.pathUnder('/storage/emulated/0/Music', folder), isTrue);
    // A sibling whose name shares the prefix must not match.
    expect(
      MusicService.pathUnder('/storage/emulated/0/MusicBackup/a.mp3', folder),
      isFalse,
    );
    expect(MusicService.pathUnder('/storage/emulated/0/Download/a.mp3', folder), isFalse);
    expect(MusicService.pathUnder('/storage/emulated/0/Music/a.mp3', ''), isFalse);
  });

  test('parentDirOf and baseName', () {
    expect(
      MusicService.parentDirOf('/storage/emulated/0/Music/a.mp3'),
      '/storage/emulated/0/Music',
    );
    expect(MusicService.parentDirOf('/storage/emulated/0'), '/storage/emulated');
    expect(MusicService.parentDirOf('/storage'), isNull);
    expect(MusicService.baseName('/storage/emulated/0/Music'), 'Music');
    expect(MusicService.baseName('/storage/emulated/0'), '0');
  });

  test('volumeRootOf splits internal storage and SD cards', () {
    expect(
      MusicService.volumeRootOf('/storage/emulated/0/Music/a.mp3'),
      '/storage/emulated/0',
    );
    expect(
      MusicService.volumeRootOf('/storage/emulated/0'),
      '/storage/emulated/0',
    );
    expect(
      MusicService.volumeRootOf('/storage/0000-0000/Music/sub/a.mp3'),
      '/storage/0000-0000',
    );
    expect(MusicService.volumeRootOf('/data/data/a.mp3'), isNull);
  });

  test('folderLabel shows the path after its volume root', () {
    expect(
      MusicService.folderLabel('/storage/emulated/0/Music/周杰伦'),
      'Music/周杰伦',
    );
    expect(MusicService.folderLabel('/storage/emulated/0'), '内部存储');
    expect(
      MusicService.folderLabel('/storage/0000-0000/Netease'),
      'SD · Netease',
    );
    expect(MusicService.folderLabel('/storage/0000-0000'), 'SD 卡');
  });
}
