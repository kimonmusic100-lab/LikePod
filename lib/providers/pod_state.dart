import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/album_model.dart';
import '../models/menu_item.dart';
import '../models/song_model.dart';
import '../services/music_service.dart';
import '../services/sound_service.dart';
import '../theme/pod_theme.dart';

enum NowPlayingSubMode {
  volume,
  scrub,
  rating,
}

class PodState extends ChangeNotifier {
  final SoundService _soundService = SoundService();
  final MusicService _musicService = MusicService();

  // Settings
  ShellThemeType _shellType = ShellThemeType.spaceGray;
  ScreenThemeType _screenType = ScreenThemeType.colorLcd;
  bool _soundEnabled = true;
  bool _hapticsEnabled = true;

  // Navigation Stack
  final List<PodMenuScreen> _screenStack = [];
  final List<int> _indexStack = [];

  // Playback State
  bool _isPlaying = false;
  String _currentTitle = 'No Track Selected';
  String _currentArtist = 'LikePod';
  String _currentAlbum = 'Local Library';
  double _playbackProgress = 0.0;
  int _currentDurationSeconds = 0;
  int _currentPositionSeconds = 0;
  int _batteryLevel = 100;
  Timer? _batteryTimer;
  bool _hasActivePlayback = false;
  Uint8List? _currentArtworkBytes;

  bool _isShowingVolume = false;
  Timer? _volumeBarTimer;

  // Phase 2: Now Playing sub-modes & ratings
  NowPlayingSubMode _nowPlayingMode = NowPlayingSubMode.volume;
  int _scrubPositionSeconds = 0;
  Timer? _subModeTimer;
  final Map<int, int> _songRatings = {};

  // Phase 2: 3D Cover Flow
  List<AlbumModel> _albums = [];
  int _coverFlowIndex = 0;

  StreamSubscription? _playerStateSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;

  PodState() {
    _initAudioListeners();
    _initMenuHierarchy();
    _initBatteryMonitor();
  }

  // Getters
  ShellThemeType get shellType => _shellType;
  ScreenThemeType get screenType => _screenType;
  bool get soundEnabled => _soundEnabled;
  bool get hapticsEnabled => _hapticsEnabled;
  PodTheme get currentTheme => PodTheme.getTheme(_shellType, _screenType);

  bool get isPlaying => _isPlaying;
  String get currentTitle => _currentTitle;
  String get currentArtist => _currentArtist;
  String get currentAlbum => _currentAlbum;
  double get playbackProgress => _playbackProgress;
  int get currentDurationSeconds => _currentDurationSeconds;
  int get currentPositionSeconds => _currentPositionSeconds;
  int get batteryLevel => _batteryLevel;
  bool get hasActivePlayback => _hasActivePlayback || _musicService.currentSong != null;
  int get queuePosition {
    final idx = _musicService.queueIndex;
    return idx >= 0 ? idx + 1 : 0;
  }
  int get queueLength => _musicService.queueLength;
  SongModel? get currentSong => _musicService.currentSong;
  Uint8List? get currentArtworkBytes => _currentArtworkBytes;
  bool get isShowingVolume => _isShowingVolume;
  double get volume => _musicService.volume;

  // Phase 2 Getters
  NowPlayingSubMode get nowPlayingMode => _nowPlayingMode;
  int get scrubPositionSeconds => _scrubPositionSeconds;
  int get currentSongRating {
    final song = _musicService.currentSong;
    if (song == null) return 0;
    return _songRatings[song.id] ?? 0;
  }
  PodShuffleMode get shuffleMode => _musicService.shuffleMode;
  PodRepeatMode get repeatMode => _musicService.repeatMode;
  List<AlbumModel> get albums => _albums;
  int get coverFlowIndex => _coverFlowIndex;
  AlbumModel? get currentCoverFlowAlbum =>
      (_albums.isNotEmpty && _coverFlowIndex >= 0 && _coverFlowIndex < _albums.length)
          ? _albums[_coverFlowIndex]
          : null;

  Future<dynamic> getArtwork(int? albumId) => _musicService.getArtwork(albumId);

  /// Best artwork for the split-view right pane for [item].
  /// Prefers now-playing art, then item album id, then first library cover.
  Uint8List? previewArtworkFor(PodMenuItem item) {
    if (item.previewAlbumId != null) {
      for (final album in _albums) {
        if (album.albumId == item.previewAlbumId && album.artworkBytes != null) {
          return album.artworkBytes;
        }
      }
    }

    if (item.id == 'music_cover_flow' || item.id == 'cover_flow') {
      final cf = currentCoverFlowAlbum;
      if (cf?.artworkBytes != null) return cf!.artworkBytes;
    }

    if (_currentArtworkBytes != null) {
      return _currentArtworkBytes;
    }

    for (final album in _albums) {
      if (album.artworkBytes != null) {
        return album.artworkBytes;
      }
    }

    return null;
  }

  PodMenuScreen get currentScreen =>
      _screenStack.isNotEmpty ? _screenStack.last : _buildMainMenu();

  int get currentSelectedIndex =>
      _indexStack.isNotEmpty ? _indexStack.last : 0;

  bool get canGoBack => _screenStack.length > 1;

  void _initAudioListeners() {
    _musicService.init().then((_) {
      _rebuildMenus();
    });

    _playerStateSub = _musicService.player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      final song = _musicService.currentSong;
      if (song != null) {
        _hasActivePlayback = true;
        if (_currentTitle != song.title) {
          _currentTitle = song.title;
          _currentArtist = song.artist;
          _currentAlbum = song.album;
          _loadArtworkForSong(song);
        }
      }
      notifyListeners();
    });

    _positionSub = _musicService.player.positionStream.listen((pos) {
      _currentPositionSeconds = pos.inSeconds;
      if (_currentDurationSeconds > 0) {
        _playbackProgress = (_currentPositionSeconds / _currentDurationSeconds).clamp(0.0, 1.0);
      }
      notifyListeners();
    });

    _durationSub = _musicService.player.durationStream.listen((dur) {
      if (dur != null && dur.inSeconds > 0) {
        _currentDurationSeconds = dur.inSeconds;
      } else {
        final song = _musicService.currentSong;
        if (song != null && song.durationMs > 0) {
          _currentDurationSeconds = song.durationMs ~/ 1000;
        }
      }
      notifyListeners();
    });
  }

  void _rebuildMenus() {
    _buildAlbumsList();
    if (_screenStack.isNotEmpty && _screenStack.first.id == 'main') {
      _screenStack[0] = _buildMainMenu();
      notifyListeners();
    }
  }

  void _buildAlbumsList() {
    final songs = _musicService.allSongs;
    final Map<String, List<SongModel>> map = {};
    for (final s in songs) {
      map.putIfAbsent(s.album, () => []).add(s);
    }
    _albums = map.entries.map((entry) {
      return AlbumModel(
        title: entry.key,
        artist: entry.value.first.artist,
        albumId: entry.value.first.albumId,
        songs: entry.value,
      );
    }).toList();

    for (final album in _albums) {
      _musicService.getArtwork(album.albumId).then((bytes) {
        if (bytes != null) {
          album.artworkBytes = bytes;
          notifyListeners();
        }
      });
    }
  }

  void _initMenuHierarchy() {
    final root = _buildMainMenu();
    _screenStack.clear();
    _indexStack.clear();
    _screenStack.add(root);
    _indexStack.add(0);
  }

  PodMenuScreen _buildMainMenu() {
    return PodMenuScreen(
      id: 'main',
      title: 'iPod',
      isSplitView: true,
      items: [
        PodMenuItem(
          id: 'music',
          title: '音乐',
          previewType: PreviewType.artwork,
          previewIcon: Icons.music_note_rounded,
          subMenuSplitView: true,
          subMenuItems: () => [
            PodMenuItem(
              id: 'music_cover_flow',
              title: 'Cover Flow',
              previewType: PreviewType.artwork,
              previewIcon: Icons.view_carousel_rounded,
              hasSubmenu: false,
              onSelect: () => _openCoverFlow(),
            ),
            PodMenuItem(
              id: 'genius_mixes',
              title: 'Genius 混合曲目',
              previewType: PreviewType.artwork,
              previewIcon: Icons.auto_awesome_rounded,
              subMenuItems: () => _buildStubMenu('无 Genius 混合曲目'),
            ),
            PodMenuItem(
              id: 'playlists',
              title: '播放列表',
              previewType: PreviewType.artwork,
              previewIcon: Icons.playlist_play_rounded,
              subMenuItems: () => [
                PodMenuItem(
                  id: 'all_songs_playlist',
                  title: '所有歌曲 (${_musicService.allSongs.length})',
                  hasSubmenu: false,
                  onSelect: () {
                    if (_musicService.allSongs.isNotEmpty) {
                      _playSong(_musicService.allSongs.first, queue: _musicService.allSongs);
                    }
                  },
                ),
                PodMenuItem(
                  id: 'rescan',
                  title: '重新扫描',
                  hasSubmenu: false,
                  onSelect: () async {
                    await _musicService.scanLocalMusic();
                    _rebuildMenus();
                  },
                ),
              ],
            ),
            PodMenuItem(
              id: 'artists',
              title: '表演者',
              previewType: PreviewType.artwork,
              previewIcon: Icons.person_rounded,
              subMenuItems: () => _buildArtistsMenu(),
            ),
            PodMenuItem(
              id: 'albums',
              title: '专辑',
              previewType: PreviewType.artwork,
              previewIcon: Icons.album_rounded,
              subMenuItems: () => _buildAlbumsMenu(),
            ),
            PodMenuItem(
              id: 'compilations',
              title: '选集',
              previewType: PreviewType.artwork,
              previewIcon: Icons.library_music_rounded,
              subMenuItems: () => _buildStubMenu('无选集'),
            ),
            PodMenuItem(
              id: 'songs',
              title: '歌曲',
              previewType: PreviewType.artwork,
              previewIcon: Icons.audiotrack_rounded,
              subMenuTwoLineRows: true,
              subMenuItems: () => _buildSongsMenu(),
            ),
            PodMenuItem(
              id: 'genres',
              title: '风格',
              previewType: PreviewType.artwork,
              previewIcon: Icons.category_rounded,
              subMenuItems: () => _buildStubMenu('无风格'),
            ),
            PodMenuItem(
              id: 'composers',
              title: '作曲家',
              previewType: PreviewType.artwork,
              previewIcon: Icons.edit_note_rounded,
              subMenuItems: () => _buildStubMenu('无作曲家'),
            ),
          ],
        ),
        PodMenuItem(
          id: 'videos',
          title: '视频',
          previewType: PreviewType.icon,
          previewIcon: Icons.movie_rounded,
          subMenuItems: () => _buildStubMenu('无视频'),
        ),
        PodMenuItem(
          id: 'photos',
          title: '照片',
          previewType: PreviewType.icon,
          previewIcon: Icons.photo_rounded,
          subMenuItems: () => _buildStubMenu('无照片'),
        ),
        PodMenuItem(
          id: 'podcasts',
          title: 'Podcast',
          previewType: PreviewType.icon,
          previewIcon: Icons.podcasts_rounded,
          subMenuItems: () => _buildStubMenu('无 Podcast'),
        ),
        PodMenuItem(
          id: 'extras',
          title: '附加功能',
          previewType: PreviewType.icon,
          previewIcon: Icons.extension_rounded,
          subMenuItems: () => _buildStubMenu('暂无附加功能'),
        ),
        PodMenuItem(
          id: 'settings',
          title: '设置',
          previewType: PreviewType.icon,
          previewIcon: Icons.settings_rounded,
          subMenuItems: () => [
            PodMenuItem(
              id: 'shell_theme',
              title: '机身外观',
              subtitle: _getShellName(_shellType),
              subMenuItems: () => [
                PodMenuItem(
                  id: 'theme_space_gray',
                  title: 'Space Gray',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.spaceGray),
                ),
                PodMenuItem(
                  id: 'theme_white',
                  title: 'Classic White',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.classicWhite),
                ),
                PodMenuItem(
                  id: 'theme_silver',
                  title: 'Metallic Silver',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.metallicSilver),
                ),
                PodMenuItem(
                  id: 'theme_black',
                  title: 'Stealth Black',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.stealthBlack),
                ),
                PodMenuItem(
                  id: 'theme_u2',
                  title: 'U2 Special Edition',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.u2Special),
                ),
                PodMenuItem(
                  id: 'theme_sepia',
                  title: 'Sepia Nostalgia',
                  hasSubmenu: false,
                  onSelect: () => setShellType(ShellThemeType.sepiaGold),
                ),
              ],
            ),
            PodMenuItem(
              id: 'screen_theme',
              title: '屏幕风格',
              subtitle: _getScreenName(_screenType),
              subMenuItems: () => [
                PodMenuItem(
                  id: 'screen_color',
                  title: 'Classic Color LCD',
                  hasSubmenu: false,
                  onSelect: () => setScreenType(ScreenThemeType.colorLcd),
                ),
                PodMenuItem(
                  id: 'screen_sepia',
                  title: 'Warm Sepia',
                  hasSubmenu: false,
                  onSelect: () => setScreenType(ScreenThemeType.sepiaRetro),
                ),
                PodMenuItem(
                  id: 'screen_green',
                  title: 'Monochrome Green',
                  hasSubmenu: false,
                  onSelect: () => setScreenType(ScreenThemeType.monochromeGreen),
                ),
                PodMenuItem(
                  id: 'screen_dark',
                  title: 'Dark OLED',
                  hasSubmenu: false,
                  onSelect: () => setScreenType(ScreenThemeType.darkOled),
                ),
              ],
            ),
            PodMenuItem(
              id: 'repeat_setting',
              title: '重复',
              subtitle: _getRepeatName(_musicService.repeatMode),
              subMenuItems: () => [
                PodMenuItem(
                  id: 'repeat_off',
                  title: '关闭',
                  hasSubmenu: false,
                  onSelect: () {
                    _musicService.setRepeatMode(PodRepeatMode.off);
                    notifyListeners();
                  },
                ),
                PodMenuItem(
                  id: 'repeat_all',
                  title: '全部歌曲',
                  hasSubmenu: false,
                  onSelect: () {
                    _musicService.setRepeatMode(PodRepeatMode.all);
                    notifyListeners();
                  },
                ),
                PodMenuItem(
                  id: 'repeat_one',
                  title: '单曲',
                  hasSubmenu: false,
                  onSelect: () {
                    _musicService.setRepeatMode(PodRepeatMode.one);
                    notifyListeners();
                  },
                ),
              ],
            ),
            PodMenuItem(
              id: 'shuffle_setting',
              title: '随机播放',
              subtitle: _musicService.shuffleMode == PodShuffleMode.songs ? '歌曲' : '关闭',
              subMenuItems: () => [
                PodMenuItem(
                  id: 'shuffle_off',
                  title: '关闭',
                  hasSubmenu: false,
                  onSelect: () {
                    _musicService.setShuffleMode(PodShuffleMode.off);
                    notifyListeners();
                  },
                ),
                PodMenuItem(
                  id: 'shuffle_songs',
                  title: '歌曲',
                  hasSubmenu: false,
                  onSelect: () {
                    _musicService.setShuffleMode(PodShuffleMode.songs);
                    notifyListeners();
                  },
                ),
              ],
            ),
            PodMenuItem(
              id: 'sound',
              title: '滚轮音效',
              subtitle: _soundEnabled ? '打开' : '关闭',
              hasSubmenu: false,
              onSelect: () {
                _soundEnabled = !_soundEnabled;
                notifyListeners();
              },
            ),
            PodMenuItem(
              id: 'haptics',
              title: '触感反馈',
              subtitle: _hapticsEnabled ? '打开' : '关闭',
              hasSubmenu: false,
              onSelect: () {
                _hapticsEnabled = !_hapticsEnabled;
                notifyListeners();
              },
            ),
            PodMenuItem(
              id: 'about',
              title: '关于 LikePod',
              hasSubmenu: false,
              onSelect: () => _openAbout(),
            ),
          ],
        ),
        PodMenuItem(
          id: 'shuffle_songs_main',
          title: '随机播放歌曲',
          previewType: PreviewType.artwork,
          previewIcon: Icons.shuffle_rounded,
          hasSubmenu: false,
          onSelect: () => shuffleAndPlayAll(),
        ),
      ],
    );
  }

  List<PodMenuItem> _buildSongsMenu() {
    final songs = _musicService.allSongs;
    if (songs.isEmpty) {
      return [
        const PodMenuItem(
          id: 'no_songs',
          title: '未找到歌曲',
          subtitle: '请检查存储',
          hasSubmenu: false,
        ),
      ];
    }

    return songs.map((song) {
      return PodMenuItem(
        id: 'song_${song.id}',
        title: song.title,
        subtitle: song.artist,
        hasSubmenu: false,
        onSelect: () => _playSong(song, queue: songs),
      );
    }).toList();
  }

  List<PodMenuItem> _buildStubMenu(String message) {
    return [
      PodMenuItem(
        id: 'stub',
        title: message,
        hasSubmenu: false,
      ),
    ];
  }

  List<PodMenuItem> _buildArtistsMenu() {
    final songs = _musicService.allSongs;
    final Map<String, List<SongModel>> artistMap = {};
    for (final s in songs) {
      artistMap.putIfAbsent(s.artist, () => []).add(s);
    }

    return artistMap.entries.map((entry) {
      return PodMenuItem(
        id: 'artist_${entry.key}',
        title: entry.key,
        subtitle: '${entry.value.length} songs',
        subMenuItems: () => entry.value.map((song) {
          return PodMenuItem(
            id: 'artist_song_${song.id}',
            title: song.title,
            subtitle: song.album,
            hasSubmenu: false,
            onSelect: () => _playSong(song, queue: entry.value),
          );
        }).toList(),
      );
    }).toList();
  }

  List<PodMenuItem> _buildAlbumsMenu() {
    final songs = _musicService.allSongs;
    final Map<String, List<SongModel>> albumMap = {};
    for (final s in songs) {
      albumMap.putIfAbsent(s.album, () => []).add(s);
    }

    return albumMap.entries.map((entry) {
      return PodMenuItem(
        id: 'album_${entry.key}',
        title: entry.key,
        subtitle: entry.value.first.artist,
        previewType: PreviewType.artwork,
        previewAlbumId: entry.value.first.albumId,
        subMenuItems: () => entry.value.map((song) {
          return PodMenuItem(
            id: 'album_song_${song.id}',
            title: song.title,
            subtitle: song.formattedDuration,
            hasSubmenu: false,
            onSelect: () => _playSong(song, queue: entry.value),
          );
        }).toList(),
      );
    }).toList();
  }

  void _playSong(SongModel song, {List<SongModel>? queue}) {
    _hasActivePlayback = true;
    _volumeBarTimer?.cancel();
    _isShowingVolume = false;
    _currentTitle = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album;
    _currentDurationSeconds = song.durationMs ~/ 1000;
    _currentPositionSeconds = 0;
    _playbackProgress = 0.0;
    _loadArtworkForSong(song);
    _musicService.playSong(song, queue: queue);
    _openNowPlaying();
  }

  Future<void> _loadArtworkForSong(SongModel? song) async {
    if (song == null) {
      _currentArtworkBytes = null;
      notifyListeners();
      return;
    }
    final bytes = await _musicService.getArtwork(song.albumId);
    _currentArtworkBytes = bytes;
    notifyListeners();
  }

  String _getShellName(ShellThemeType type) {
    switch (type) {
      case ShellThemeType.spaceGray:
        return 'Space Gray';
      case ShellThemeType.classicWhite:
        return 'Classic White';
      case ShellThemeType.stealthBlack:
        return 'Stealth Black';
      case ShellThemeType.metallicSilver:
        return 'Silver';
      case ShellThemeType.u2Special:
        return 'U2 Edition';
      case ShellThemeType.sepiaGold:
        return 'Sepia Gold';
    }
  }

  String _getScreenName(ScreenThemeType type) {
    switch (type) {
      case ScreenThemeType.colorLcd:
        return 'Color LCD';
      case ScreenThemeType.sepiaRetro:
        return 'Warm Sepia';
      case ScreenThemeType.monochromeGreen:
        return 'Mono Green';
      case ScreenThemeType.darkOled:
        return 'Dark OLED';
    }
  }

  String _getRepeatName(PodRepeatMode mode) {
    switch (mode) {
      case PodRepeatMode.off:
        return '关闭';
      case PodRepeatMode.all:
        return '全部歌曲';
      case PodRepeatMode.one:
        return '单曲';
    }
  }

  void shuffleAndPlayAll() {
    _musicService.shuffleAndPlayAll();
    _openNowPlaying();
  }

  // Rotary Wheel Actions
  void onRotate(int stepDelta) {
    if (stepDelta == 0) return;

    // 1. Cover Flow rotary album navigation
    if (currentScreen.id == 'cover_flow_view' && _albums.isNotEmpty) {
      final newIdx = (_coverFlowIndex + stepDelta).clamp(0, _albums.length - 1);
      if (newIdx != _coverFlowIndex) {
        _coverFlowIndex = newIdx;
        _soundService.playClick(
          soundEnabled: _soundEnabled,
          hapticsEnabled: _hapticsEnabled,
        );
        notifyListeners();
      }
      return;
    }

    // 2. Now Playing screen actions (Volume / Scrub / Rating)
    if (currentScreen.id == 'now_playing_view') {
      if (_nowPlayingMode == NowPlayingSubMode.volume) {
        final currentVol = _musicService.volume;
        final newVol = (currentVol + stepDelta * 0.04).clamp(0.0, 1.0);
        _musicService.setVolume(newVol);
        _isShowingVolume = true;

        _soundService.playClick(
          soundEnabled: _soundEnabled,
          hapticsEnabled: _hapticsEnabled,
        );

        _volumeBarTimer?.cancel();
        _volumeBarTimer = Timer(const Duration(seconds: 2), () {
          _isShowingVolume = false;
          notifyListeners();
        });

        notifyListeners();
        return;
      } else if (_nowPlayingMode == NowPlayingSubMode.scrub) {
        _scrubPositionSeconds = (_scrubPositionSeconds + stepDelta * 4).clamp(0, _currentDurationSeconds);
        _soundService.playClick(
          soundEnabled: _soundEnabled,
          hapticsEnabled: _hapticsEnabled,
        );
        _subModeTimer?.cancel();
        _subModeTimer = Timer(const Duration(seconds: 4), () {
          _musicService.seek(Duration(seconds: _scrubPositionSeconds));
          _nowPlayingMode = NowPlayingSubMode.volume;
          notifyListeners();
        });
        notifyListeners();
        return;
      } else if (_nowPlayingMode == NowPlayingSubMode.rating) {
        final song = _musicService.currentSong;
        if (song != null) {
          final cur = _songRatings[song.id] ?? 0;
          final updated = (cur + stepDelta).clamp(0, 5);
          _songRatings[song.id] = updated;
          _soundService.playClick(
            soundEnabled: _soundEnabled,
            hapticsEnabled: _hapticsEnabled,
          );
        }
        _subModeTimer?.cancel();
        _subModeTimer = Timer(const Duration(seconds: 4), () {
          _nowPlayingMode = NowPlayingSubMode.volume;
          notifyListeners();
        });
        notifyListeners();
        return;
      }
    }

    final items = currentScreen.items;
    if (items.isEmpty) return;

    final currentIndex = currentSelectedIndex;
    int nextIndex = currentIndex + stepDelta;
    if (nextIndex < 0) nextIndex = 0;
    if (nextIndex >= items.length) nextIndex = items.length - 1;

    if (nextIndex != currentIndex) {
      _indexStack[_indexStack.length - 1] = nextIndex;
      _soundService.playClick(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );
      notifyListeners();
    }
  }

  void onSelect() {
    // 1. Now Playing: Cycle Center Button Sub-Modes (Volume -> Scrub -> Rating -> Volume)
    if (currentScreen.id == 'now_playing_view') {
      _soundService.playConfirm(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );

      switch (_nowPlayingMode) {
        case NowPlayingSubMode.volume:
          _nowPlayingMode = NowPlayingSubMode.scrub;
          _scrubPositionSeconds = _currentPositionSeconds;
          break;
        case NowPlayingSubMode.scrub:
          _musicService.seek(Duration(seconds: _scrubPositionSeconds));
          _nowPlayingMode = NowPlayingSubMode.rating;
          break;
        case NowPlayingSubMode.rating:
          _nowPlayingMode = NowPlayingSubMode.volume;
          break;
      }

      _subModeTimer?.cancel();
      if (_nowPlayingMode != NowPlayingSubMode.volume) {
        _subModeTimer = Timer(const Duration(seconds: 4), () {
          if (_nowPlayingMode == NowPlayingSubMode.scrub) {
            _musicService.seek(Duration(seconds: _scrubPositionSeconds));
          }
          _nowPlayingMode = NowPlayingSubMode.volume;
          notifyListeners();
        });
      }
      notifyListeners();
      return;
    }

    // 2. Cover Flow: Center Select plays focused album and opens Now Playing.
    // Stack: Now Playing -> Cover Flow -> Music -> iPod main
    if (currentScreen.id == 'cover_flow_view' && _albums.isNotEmpty) {
      _soundService.playConfirm(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );
      final album = _albums[_coverFlowIndex.clamp(0, _albums.length - 1)];
      if (album.songs.isNotEmpty) {
        _playSong(album.songs.first, queue: album.songs);
      }
      return;
    }

    final items = currentScreen.items;
    if (items.isEmpty) return;

    final item = items[currentSelectedIndex];
    _soundService.playConfirm(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );

    if (item.onSelect != null) {
      item.onSelect!();
    } else if (item.hasSubmenu && item.subMenuItems != null) {
      final subItems = item.subMenuItems!();
      final newScreen = PodMenuScreen(
        id: item.id,
        title: item.title,
        items: subItems,
        isSplitView: item.subMenuSplitView,
        useTwoLineRows: item.subMenuTwoLineRows,
      );
      _screenStack.add(newScreen);
      _indexStack.add(0);
      notifyListeners();
    }
  }

  void onMenu() {
    _volumeBarTimer?.cancel();
    _subModeTimer?.cancel();
    _isShowingVolume = false;
    _nowPlayingMode = NowPlayingSubMode.volume;

    _soundService.playConfirm(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );

    if (_screenStack.length > 1) {
      _screenStack.removeLast();
      _indexStack.removeLast();
      notifyListeners();
    }
  }

  void onPlayPause() {
    _soundService.playConfirm(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.togglePlayPause();
  }

  void onNext() {
    _soundService.playClick(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.playNext();
  }

  void onPrevious() {
    _soundService.playClick(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.playPrevious();
  }

  void setSelectedIndex(int index) {
    if (index >= 0 && index < currentScreen.items.length) {
      if (_indexStack.isNotEmpty && _indexStack.last != index) {
        _indexStack[_indexStack.length - 1] = index;
        _soundService.playClick(
          soundEnabled: _soundEnabled,
          hapticsEnabled: _hapticsEnabled,
        );
        notifyListeners();
      }
    }
  }

  void setShellType(ShellThemeType type) {
    _shellType = type;
    notifyListeners();
  }

  void setScreenType(ScreenThemeType type) {
    _screenType = type;
    notifyListeners();
  }

  void _openNowPlaying() {
    _volumeBarTimer?.cancel();
    _subModeTimer?.cancel();
    _isShowingVolume = false;
    _nowPlayingMode = NowPlayingSubMode.volume;

    // Already on Now Playing — refresh only.
    if (_screenStack.isNotEmpty && _screenStack.last.id == 'now_playing_view') {
      notifyListeners();
      return;
    }

    // If an intermediate Cover Flow album tracklist is on top, drop it so
    // MENU returns: Now Playing -> Cover Flow -> Music -> main.
    while (_screenStack.length > 1 &&
        _screenStack.last.id.startsWith('cover_flow_album_')) {
      _screenStack.removeLast();
      if (_indexStack.isNotEmpty) _indexStack.removeLast();
    }

    final nowPlayingScreen = PodMenuScreen(
      id: 'now_playing_view',
      title: '\u6b63\u5728\u64ad\u653e',
      isSplitView: false,
      items: const [],
    );
    _screenStack.add(nowPlayingScreen);
    _indexStack.add(0);
    notifyListeners();
  }

  void _openCoverFlow() {
    if (_albums.isEmpty) {
      _buildAlbumsList();
    }
    if (_albums.isEmpty) {
      _coverFlowIndex = 0;
    } else {
      _coverFlowIndex = _coverFlowIndex.clamp(0, _albums.length - 1);
    }

    // Re-entering Cover Flow: reuse existing layer instead of stacking duplicates.
    if (_screenStack.isNotEmpty && _screenStack.last.id == 'cover_flow_view') {
      notifyListeners();
      return;
    }

    final coverFlowScreen = PodMenuScreen(
      id: 'cover_flow_view',
      title: 'Cover Flow',
      isSplitView: false,
      items: const [],
    );
    _screenStack.add(coverFlowScreen);
    _indexStack.add(0);
    notifyListeners();
  }

  void _openAbout() {
    final aboutScreen = PodMenuScreen(
      id: 'about_view',
      title: 'About LikePod',
      isSplitView: false,
      items: const [],
    );
    _screenStack.add(aboutScreen);
    _indexStack.add(0);
    notifyListeners();
  }


  void _initBatteryMonitor() {
    Future<void> refresh() async {
      try {
        final level = await _musicService.getBatteryLevel();
        if (level != _batteryLevel) {
          _batteryLevel = level;
          notifyListeners();
        }
      } catch (_) {}
    }

    refresh();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
  }
  @override
  void dispose() {
    _volumeBarTimer?.cancel();
    _subModeTimer?.cancel();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }
}
