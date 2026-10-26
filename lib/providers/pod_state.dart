import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/album_model.dart';
import '../models/menu_item.dart';
import '../models/song_model.dart';
import '../services/music_service.dart';
import '../services/output_probe.dart';
import '../services/settings_store.dart';
import '../services/sound_service.dart';
import '../theme/pod_theme.dart';

enum NowPlayingSubMode { volume, scrub, rating }

class PodState extends ChangeNotifier with WidgetsBindingObserver {
  final SoundService _soundService = SoundService();
  final MusicService _musicService = MusicService();
  SettingsStore? _store;
  final Completer<void> _readyCompleter = Completer<void>();

  /// Completes after saved settings have been applied (or skipped).
  Future<void> get ready => _readyCompleter.future;

  // Settings
  ShellThemeType _shellType = ShellThemeType.spaceGray;
  bool _soundEnabled = true;
  bool _hapticsEnabled = true;
  List<String> _musicFolders = const [];
  bool _qualityModeHigh = true;

  // Quality-mode picker opened by a double tap on the center dot.
  bool _modePopupVisible = false;
  int _modePopupIndex = 0;

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

  // Now Playing sub-modes and ratings
  NowPlayingSubMode _nowPlayingMode = NowPlayingSubMode.volume;
  int _scrubPositionSeconds = 0;
  Timer? _subModeTimer;
  final Map<int, int> _songRatings = {};
  bool _loadingSettings = false;
  bool _holdPersist = false;
  bool _pendingPersist = false;
  bool _disposed = false;
  bool _restoredPlayback = false;
  double? _savedVolume;
  int? _savedSongId;
  int _savedPositionMs = 0;
  List<int> _savedQueueIds = const [];
  Timer? _persistTimer;
  Future<void> _persistChain = Future<void>.value();
  DateTime? _nextPositionPersistAt;

  // Cover Flow
  List<AlbumModel> _albums = [];
  int _coverFlowIndex = 0;

  StreamSubscription? _playerStateSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;

  PodState({SettingsStore? settingsStore}) {
    WidgetsBinding.instance.addObserver(this);
    _musicService.onOutputChanged = () {
      if (_disposed) return;
      _refreshSettingsMenu();
      notifyListeners();
    };
    _initMenuHierarchy();
    _initBatteryMonitor();
    if (settingsStore != null) {
      _store = settingsStore;
      _loadingSettings = true;
      _applySettings(settingsStore.load());
      _loadingSettings = false;
      _markReady();
      _initAudioListeners();
    } else {
      unawaited(_bootstrapSettings());
    }
  }

  void _markReady() {
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future<void> _bootstrapSettings() async {
    _loadingSettings = true;
    try {
      _store = await SettingsStore.open();
      if (_disposed) return;
      _applySettings(_store!.load());
    } catch (e) {
      debugPrint('Settings load failed: $e');
    } finally {
      _loadingSettings = false;
      _markReady();
    }
    if (_disposed) return;
    if (_pendingPersist) {
      _pendingPersist = false;
      _schedulePersist(immediate: true);
    }
    _initAudioListeners();
  }

  void _applySettings(AppSettings settings) {
    _shellType = _parseShell(settings.shell);
    _soundEnabled = settings.soundEnabled;
    _hapticsEnabled = settings.hapticsEnabled;
    _musicFolders = List.unmodifiable(settings.musicFolders);
    // Must be set before the first scan, which runs in MusicService.init().
    _musicService.setMusicFolders(_musicFolders);
    _qualityModeHigh = settings.highQuality;
    unawaited(_musicService.setQualityMode(_qualityModeHigh));
    _songRatings
      ..clear()
      ..addAll(settings.ratings);
    _musicService.setShuffleMode(_parseShuffle(settings.shuffle));
    _musicService.setRepeatMode(_parseRepeat(settings.repeat));
    _savedVolume = settings.volume;
    _savedSongId = settings.lastSongId;
    _savedPositionMs = settings.lastPositionMs;
    _savedQueueIds = List<int>.from(settings.lastQueueIds);
  }

  ShellThemeType _parseShell(String name) {
    for (final value in ShellThemeType.values) {
      if (value.name == name) return value;
    }
    return ShellThemeType.spaceGray;
  }

  PodShuffleMode _parseShuffle(String name) {
    for (final value in PodShuffleMode.values) {
      if (value.name == name) return value;
    }
    return PodShuffleMode.off;
  }

  PodRepeatMode _parseRepeat(String name) {
    for (final value in PodRepeatMode.values) {
      if (value.name == name) return value;
    }
    return PodRepeatMode.all;
  }

  AppSettings _snapshot() {
    final song = _musicService.currentSong;
    return AppSettings(
      shell: _shellType.name,
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
      highQuality: _qualityModeHigh,
      musicFolders: List<String>.from(_musicFolders),
      shuffle: _musicService.shuffleMode.name,
      repeat: _musicService.repeatMode.name,
      volume: _savedVolume,
      ratings: Map<int, int>.from(_songRatings),
      lastSongId: song?.id ?? _savedSongId,
      lastPositionMs: song != null
          ? _musicService.position.inMilliseconds
          : _savedPositionMs,
      lastQueueIds: song != null
          ? _musicService.currentQueueIds
          : List<int>.from(_savedQueueIds),
    );
  }

  void _schedulePersist({bool immediate = false}) {
    if (_disposed || _loadingSettings || _holdPersist) return;
    if (_store == null) {
      _pendingPersist = true;
      return;
    }
    if (immediate) {
      _persistTimer?.cancel();
      _persistTimer = null;
      _writeSettings();
      return;
    }
    _persistTimer ??= Timer(const Duration(milliseconds: 500), _writeSettings);
  }

  void _writeSettings() {
    _persistTimer = null;
    final store = _store;
    if (store == null || _disposed || _loadingSettings || _holdPersist) return;
    final snapshot = _snapshot();
    if (snapshot.volume != null) {
      _savedVolume = snapshot.volume;
    }
    if (snapshot.lastSongId != null) {
      _savedSongId = snapshot.lastSongId;
      _savedPositionMs = snapshot.lastPositionMs;
      _savedQueueIds = List<int>.from(snapshot.lastQueueIds);
    }
    _persistChain = _persistChain.then((_) => store.save(snapshot));
  }

  void _notePositionPersist() {
    final now = DateTime.now();
    if (_nextPositionPersistAt != null &&
        now.isBefore(_nextPositionPersistAt!)) {
      return;
    }
    _nextPositionPersistAt = now.add(const Duration(seconds: 5));
    _schedulePersist(immediate: true);
  }

  /// Waits until any in-flight settings write has finished.
  @visibleForTesting
  Future<void> flushSettings() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    _writeSettings();
    await _persistChain;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background =
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused;
    _musicService.setInBackground(background);
    if (background || state == AppLifecycleState.detached) {
      _schedulePersist(immediate: true);
      if (_isPlaying && state != AppLifecycleState.detached) {
        unawaited(_musicService.anchorPlayback(true));
      }
    }
  }

  // Getters
  ShellThemeType get shellType => _shellType;
  bool get soundEnabled => _soundEnabled;
  bool get hapticsEnabled => _hapticsEnabled;
  bool get qualityModeHigh => _qualityModeHigh;
  bool get modePopupVisible => _modePopupVisible;
  int get modePopupIndex => _modePopupIndex;
  PodTheme get currentTheme => PodTheme.getTheme(_shellType);

  bool get isPlaying => _isPlaying;
  String get currentTitle => _currentTitle;
  String get currentArtist => _currentArtist;
  String get currentAlbum => _currentAlbum;
  double get playbackProgress => _playbackProgress;
  int get currentDurationSeconds => _currentDurationSeconds;
  int get currentPositionSeconds => _currentPositionSeconds;
  int get batteryLevel => _batteryLevel;
  bool get hasActivePlayback =>
      _hasActivePlayback || _musicService.currentSong != null;
  OutputSnapshot get outputSnapshot => _musicService.outputSnapshot;
  int get queuePosition {
    final idx = _musicService.queueIndex;
    return idx >= 0 ? idx + 1 : 0;
  }

  int get queueLength => _musicService.queueLength;
  SongModel? get currentSong => _musicService.currentSong;
  Uint8List? get currentArtworkBytes => _currentArtworkBytes;
  bool get isShowingVolume => _isShowingVolume;
  double get volume => _musicService.volume;

  // Now Playing and Cover Flow
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
      (_albums.isNotEmpty &&
          _coverFlowIndex >= 0 &&
          _coverFlowIndex < _albums.length)
      ? _albums[_coverFlowIndex]
      : null;

  /// Best artwork for the split-view right pane for [item].
  /// Prefers now-playing art, then item album id, then first library cover.
  Uint8List? previewArtworkFor(PodMenuItem item) {
    if (item.previewAlbumId != null) {
      for (final album in _albums) {
        if (album.albumId == item.previewAlbumId &&
            album.artworkBytes != null) {
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

  int get currentSelectedIndex => _indexStack.isNotEmpty ? _indexStack.last : 0;

  bool get canGoBack => _screenStack.length > 1;

  void _initAudioListeners() {
    if (_musicService.ensurePlayer()) {
      _playerStateSub = _musicService.player.playerStateStream.listen((state) {
        final wasActive = _hasActivePlayback;
        final wasPlaying = _isPlaying;
        _isPlaying = state.playing;
        final song = _musicService.currentSong;
        if (song != null) {
          _hasActivePlayback = true;
          if (_currentTitle != song.title) {
            _currentTitle = song.title;
            _currentArtist = song.artist;
            _currentAlbum = song.album;
            _loadArtworkForSong(song);
            _schedulePersist(immediate: true);
          }
        }
        if (!wasActive && _hasActivePlayback) {
          _refreshPlaybackMenus();
        }
        if (wasPlaying && !state.playing) {
          _schedulePersist(immediate: true);
        }
        if (!_disposed) notifyListeners();
      });

      _positionSub = _musicService.player.positionStream.listen((pos) {
        _currentPositionSeconds = pos.inSeconds;
        if (_currentDurationSeconds > 0) {
          _playbackProgress =
              (_currentPositionSeconds / _currentDurationSeconds).clamp(
                0.0,
                1.0,
              );
        }
        if (_isPlaying) {
          _notePositionPersist();
        }
        if (!_disposed) notifyListeners();
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
        if (!_disposed) notifyListeners();
      });
    }

    _musicService.init().then((_) async {
      if (_disposed) return;
      final savedVolume = _savedVolume;
      if (savedVolume != null) {
        await _musicService.setVolume(savedVolume, writeSystem: false);
      }
      if (_disposed) return;
      await _restorePlaybackIfAny();
      if (_disposed) return;
      _rebuildMenus();
    });
  }

  Future<void> _restorePlaybackIfAny() async {
    final songId = _savedSongId;
    if (songId == null || _restoredPlayback) return;
    _restoredPlayback = true;

    final songs = _musicService.allSongs;
    SongModel? song;
    for (final candidate in songs) {
      if (candidate.id == songId) {
        song = candidate;
        break;
      }
    }
    final SongModel? restored = song;
    if (restored == null) return;

    final queue = <SongModel>[];
    for (final id in _savedQueueIds) {
      for (final candidate in songs) {
        if (candidate.id == id) {
          queue.add(candidate);
          break;
        }
      }
    }
    if (!queue.any((item) => item.id == restored.id)) {
      queue.insert(0, restored);
    }

    _hasActivePlayback = true;
    _currentTitle = restored.title;
    _currentArtist = restored.artist;
    _currentAlbum = restored.album;
    _currentDurationSeconds = restored.durationMs ~/ 1000;
    _currentPositionSeconds = _savedPositionMs ~/ 1000;
    if (_currentDurationSeconds > 0) {
      _playbackProgress = (_currentPositionSeconds / _currentDurationSeconds)
          .clamp(0.0, 1.0);
    }
    _loadArtworkForSong(restored);

    _holdPersist = true;
    try {
      await _musicService.restorePaused(
        restored,
        queue: queue,
        position: Duration(milliseconds: _savedPositionMs),
      );
    } finally {
      _holdPersist = false;
    }
    _refreshPlaybackMenus();
    if (!_disposed) notifyListeners();
  }

  void _rebuildMenus() {
    _buildAlbumsList();
    _refreshPlaybackMenus();
    if (!_disposed) notifyListeners();
  }

  /// Rebuilds the root menu so 「正在播放」 tracks whether a song is loaded,
  /// and the Music menu so its play-mode title stays current.
  void _refreshPlaybackMenus() {
    if (_screenStack.isEmpty || _screenStack.first.id != 'main') return;
    final root = _buildMainMenu();
    _screenStack[0] = root;
    if (_indexStack.isNotEmpty) {
      final last = root.items.isEmpty ? 0 : root.items.length - 1;
      if (_indexStack[0] > last) _indexStack[0] = last;
    }
    for (var i = 1; i < _screenStack.length; i++) {
      if (_screenStack[i].id != 'music') continue;
      final items = _musicMenuItems();
      final last = items.isEmpty ? 0 : items.length - 1;
      _screenStack[i] = PodMenuScreen(
        id: 'music',
        title: '音乐',
        items: items,
        isSplitView: true,
      );
      if (i < _indexStack.length && _indexStack[i] > last) {
        _indexStack[i] = last;
      }
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
      title: 'LikePod',
      isSplitView: true,
      items: [
        PodMenuItem(
          id: 'music',
          title: '音乐',
          previewType: PreviewType.artwork,
          previewIcon: Icons.music_note_rounded,
          subMenuSplitView: true,
          subMenuItems: _musicMenuItems,
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
          id: 'settings',
          title: '设置',
          previewType: PreviewType.icon,
          previewIcon: Icons.settings_rounded,
          subMenuItems: _settingsMenuItems,
        ),
        if (hasActivePlayback) _nowPlayingItem(id: 'main_now_playing'),
      ],
    );
  }

  List<PodMenuItem> _settingsMenuItems() {
    return [
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
        ],
      ),
      PodMenuItem(
        id: 'music_folders',
        title: '音乐文件夹',
        subtitle: _musicFolders.isEmpty ? '未选择' : '${_musicFolders.length} 个目录',
        subMenuItems: _musicFolderItems,
      ),
      PodMenuItem(
        id: 'sound',
        title: '滚轮音效',
        subtitle: _soundEnabled ? '打开' : '关闭',
        hasSubmenu: false,
        onSelect: () {
          _soundEnabled = !_soundEnabled;
          _refreshSettingsMenu();
          notifyListeners();
          _schedulePersist(immediate: true);
        },
      ),
      PodMenuItem(
        id: 'haptics',
        title: '触感反馈',
        subtitle: _hapticsEnabled ? '打开' : '关闭',
        hasSubmenu: false,
        onSelect: () {
          _hapticsEnabled = !_hapticsEnabled;
          _refreshSettingsMenu();
          notifyListeners();
          _schedulePersist(immediate: true);
        },
      ),
      PodMenuItem(
        id: 'about',
        title: '关于 LikePod',
        hasSubmenu: false,
        onSelect: () => _openAbout(),
      ),
    ];
  }

  /// The whitelist screen: every added folder plus the add-directory entry.
  /// The library is empty until the user adds folders here.
  List<PodMenuItem> _musicFolderItems() {
    return [
      if (_musicFolders.isEmpty)
        PodMenuItem(
          id: 'music_folders_empty',
          title: '未添加目录，曲库为空',
          hasSubmenu: false,
        )
      else
        for (final folder in _musicFolders)
          PodMenuItem(
            id: 'music_folder_${folder.hashCode}',
            title: MusicService.folderLabel(folder),
            subtitle: '${_musicService.songsUnder(folder)} 首 · 轻点移除',
            hasSubmenu: false,
            onSelect: () => _removeMusicFolder(folder),
          ),
      PodMenuItem(
        id: 'add_folder',
        title: '添加目录',
        subtitle: '浏览并选择',
        subMenuItems: () => _folderBrowserItems(null),
      ),
    ];
  }

  /// Browser level for [dir]; null lists the storage volumes.
  List<PodMenuItem> _folderBrowserItems(String? dir) {
    if (dir == null) {
      return [
        for (final root in _musicService.storageRoots())
          PodMenuItem(
            id: 'folder_browser:$root',
            title: MusicService.folderLabel(root),
            subtitle: '${_musicService.songsUnder(root)} 首',
            subMenuItems: () => _folderBrowserItems(root),
          ),
      ];
    }
    return [
      PodMenuItem(
        id: 'folder_pick:$dir',
        title: '选择此目录',
        subtitle: '${_musicService.songsUnder(dir)} 首',
        hasSubmenu: false,
        onSelect: () => _selectMusicFolder(dir),
      ),
      for (final child in _musicService.childFolders(dir))
        PodMenuItem(
          id: 'folder_browser:$child',
          title: MusicService.baseName(child),
          subtitle: '${_musicService.songsUnder(child)} 首',
          subMenuItems: () => _folderBrowserItems(child),
        ),
    ];
  }

  /// Adds one folder to the whitelist, rescans, and closes the browser.
  void _selectMusicFolder(String folder) {
    if (_musicFolders.contains(folder)) return;
    _musicFolders = List.unmodifiable([..._musicFolders, folder]);
    _musicService.setMusicFolders(_musicFolders);
    _schedulePersist(immediate: true);
    unawaited(_rescanLibrary());
    _popToMusicFoldersScreen();
    _refreshSettingsMenu();
    notifyListeners();
  }

  void _removeMusicFolder(String folder) {
    _musicFolders = List.unmodifiable(
      _musicFolders.where((f) => f != folder),
    );
    _musicService.setMusicFolders(_musicFolders);
    _schedulePersist(immediate: true);
    unawaited(_rescanLibrary());
    _refreshSettingsMenu();
    notifyListeners();
  }

  /// Pops every directory-browser level opened by 添加目录.
  void _popToMusicFoldersScreen() {
    while (_screenStack.length > 1 && _screenStack.last.id != 'music_folders') {
      _screenStack.removeLast();
      _indexStack.removeLast();
    }
  }

  Future<void> _rescanLibrary() async {
    await _musicService.scanLocalMusic();
    if (_disposed) return;
    _rebuildMenus();
    _refreshSettingsMenu();
  }

  void _refreshSettingsMenu() {
    for (var i = 0; i < _screenStack.length; i++) {
      final id = _screenStack[i].id;
      final List<PodMenuItem> items;
      final String title;
      if (id == 'settings') {
        items = _settingsMenuItems();
        title = '设置';
      } else if (id == 'music_folders') {
        items = _musicFolderItems();
        title = '音乐文件夹';
      } else if (id == 'add_folder') {
        items = _folderBrowserItems(null);
        title = '选择目录';
      } else if (id.startsWith('folder_browser:')) {
        final dir = id.substring('folder_browser:'.length);
        items = _folderBrowserItems(dir);
        title = MusicService.baseName(dir);
      } else {
        continue;
      }
      final last = items.isEmpty ? 0 : items.length - 1;
      _screenStack[i] = PodMenuScreen(
        id: id,
        title: title,
        items: items,
        isSplitView: false,
      );
      if (i < _indexStack.length && _indexStack[i] > last) {
        _indexStack[i] = last;
      }
    }
  }

  List<PodMenuItem> _musicMenuItems() {
    return [
      PodMenuItem(
        id: 'music_cover_flow',
        title: 'Cover Flow',
        previewType: PreviewType.artwork,
        previewIcon: Icons.view_carousel_rounded,
        hasSubmenu: false,
        onSelect: () => _openCoverFlow(),
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
                _playSong(
                  _musicService.allSongs.first,
                  queue: _musicService.allSongs,
                );
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
        id: 'songs',
        title: '歌曲',
        previewType: PreviewType.artwork,
        previewIcon: Icons.audiotrack_rounded,
        subMenuTwoLineRows: true,
        subMenuItems: () => _buildSongsMenu(),
      ),
      PodMenuItem(
        id: 'play_mode',
        title: playModeLabel,
        hasSubmenu: false,
        onSelect: cyclePlayMode,
      ),
    ];
  }

  PodMenuItem _nowPlayingItem({required String id}) {
    return PodMenuItem(
      id: id,
      title: '正在播放',
      previewType: PreviewType.artwork,
      previewIcon: Icons.play_arrow_rounded,
      hasSubmenu: false,
      onSelect: _openNowPlaying,
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
    return [PodMenuItem(id: 'stub', title: message, hasSubmenu: false)];
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
    _refreshPlaybackMenus();
    _schedulePersist(immediate: true);
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
    if (!_disposed) notifyListeners();
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
    }
  }

  /// The row title itself is the active mode: 随机播放 → 单曲循环 → 顺序播放.
  String get playModeLabel {
    if (_musicService.shuffleMode == PodShuffleMode.songs) return '随机播放';
    if (_musicService.repeatMode == PodRepeatMode.one) return '单曲循环';
    return '顺序播放';
  }

  void cyclePlayMode() {
    if (_musicService.shuffleMode == PodShuffleMode.songs) {
      _musicService.setShuffleMode(PodShuffleMode.off);
      _musicService.setRepeatMode(PodRepeatMode.one);
    } else if (_musicService.repeatMode == PodRepeatMode.one) {
      _musicService.setShuffleMode(PodShuffleMode.off);
      _musicService.setRepeatMode(PodRepeatMode.all);
    } else {
      _musicService.setShuffleMode(PodShuffleMode.songs);
      _musicService.setRepeatMode(PodRepeatMode.all);
    }
    _refreshPlaybackMenus();
    notifyListeners();
    _schedulePersist(immediate: true);
  }

  // Rotary Wheel Actions
  void onRotate(int stepDelta) {
    if (stepDelta == 0) return;

    // 0. Quality-mode picker: the ring moves the highlight.
    if (_modePopupVisible) {
      final next = (_modePopupIndex + stepDelta).clamp(0, 1);
      if (next != _modePopupIndex) {
        _modePopupIndex = next;
        _soundService.playTick(
          soundEnabled: _soundEnabled,
          hapticsEnabled: _hapticsEnabled,
        );
        notifyListeners();
      }
      return;
    }

    // 1. Cover Flow rotary album navigation
    if (currentScreen.id == 'cover_flow_view' && _albums.isNotEmpty) {
      final newIdx = (_coverFlowIndex + stepDelta).clamp(0, _albums.length - 1);
      if (newIdx != _coverFlowIndex) {
        _coverFlowIndex = newIdx;
        _soundService.playTick(
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
        _savedVolume = newVol;
        _isShowingVolume = true;
        _schedulePersist();

        _soundService.playTick(
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
        _scrubPositionSeconds = (_scrubPositionSeconds + stepDelta * 4).clamp(
          0,
          _currentDurationSeconds,
        );
        _soundService.playTick(
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
          _schedulePersist(immediate: true);
          _soundService.playTick(
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
      _soundService.playTick(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );
      notifyListeners();
    }
  }

  /// A long press on the click-wheel center dot opens the quality-mode
  /// picker.
  void onCenterLongPress() {
    _soundService.playSelect(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _modePopupIndex = _qualityModeHigh ? 0 : 1;
    _modePopupVisible = true;
    notifyListeners();
  }

  void _closeModePopup({required bool apply}) {
    if (!_modePopupVisible) return;
    _modePopupVisible = false;
    if (apply) {
      final high = _modePopupIndex == 0;
      if (high != _qualityModeHigh) {
        _qualityModeHigh = high;
        unawaited(_musicService.setQualityMode(high));
        _schedulePersist(immediate: true);
      }
    }
    notifyListeners();
  }

  void onSelect() {
    // 0. Quality-mode picker: the center dot confirms the highlighted row.
    if (_modePopupVisible) {
      _soundService.playSelect(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );
      _closeModePopup(apply: true);
      return;
    }

    // 1. Now Playing: Cycle Center Button Sub-Modes (Volume -> Scrub -> Rating -> Volume)
    if (currentScreen.id == 'now_playing_view') {
      _soundService.playSelect(
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
      _soundService.playSelect(
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
    _soundService.playSelect(
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

  /// Hardware back matches MENU. At the root menu it does not leave the app.
  bool handleSystemBack() {
    if (_screenStack.length > 1) {
      onMenu();
      return true;
    }
    return false;
  }

  void onMenu() {
    // The quality-mode picker closes first, like a modal sheet.
    if (_modePopupVisible) {
      _soundService.playSelect(
        soundEnabled: _soundEnabled,
        hapticsEnabled: _hapticsEnabled,
      );
      _closeModePopup(apply: false);
      return;
    }
    _volumeBarTimer?.cancel();
    _subModeTimer?.cancel();
    _isShowingVolume = false;
    _nowPlayingMode = NowPlayingSubMode.volume;

    _soundService.playSelect(
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
    // Transport keys are ignored while the mode picker is up.
    if (_modePopupVisible) return;
    _soundService.playSelect(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.togglePlayPause();
  }

  void onNext() {
    if (_modePopupVisible) return;
    _soundService.playTick(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.playNext();
  }

  void onPrevious() {
    if (_modePopupVisible) return;
    _soundService.playTick(
      soundEnabled: _soundEnabled,
      hapticsEnabled: _hapticsEnabled,
    );
    _musicService.playPrevious();
  }

  void setSelectedIndex(int index) {
    if (index >= 0 && index < currentScreen.items.length) {
      if (_indexStack.isNotEmpty && _indexStack.last != index) {
        _indexStack[_indexStack.length - 1] = index;
        _soundService.playTick(
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
    _schedulePersist(immediate: true);
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
        if (!_disposed && level != _batteryLevel) {
          _batteryLevel = level;
          notifyListeners();
        }
      } catch (_) {}
    }

    refresh();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => refresh(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _batteryTimer?.cancel();
    _volumeBarTimer?.cancel();
    _subModeTimer?.cancel();
    _persistTimer?.cancel();
    final store = _store;
    if (store != null && !_loadingSettings && !_holdPersist) {
      unawaited(store.save(_snapshot()));
    }
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }
}
