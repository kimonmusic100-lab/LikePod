import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/album_model.dart';
import '../models/menu_item.dart';
import '../providers/pod_state.dart';
import '../theme/classic_glass.dart';
import '../theme/pod_theme.dart';
import 'bluetooth_mark.dart';
import 'cover_flow_pose.dart';
import 'edge_scroll.dart';
import 'now_playing_wave.dart';

/// Light-blue wash for songs that are already in the playlist being edited.
const Color addedSongRowColor = Color(0xFFC5E6F6);

/// The tilted cover reads high. The cover and the titles drop together.
const double nowPlayingBlockDrop = 12;

/// Cover card scale inside its slot. The slot width stays put.
const double nowPlayingCoverScale = 0.9;

/// Y tilt of the Now Playing cover, around the card's right edge.
const double nowPlayingCoverTilt = -0.32;

/// Perspective term on the cover tilt (`Matrix4` entry row 3, column 2).
const double nowPlayingCoverPerspective = 0.0026;

/// Distance from the cover slot's left edge to the tilted art's left edge.
///
/// The art starts at the slot's left. The tilt pivots on the slot's right
/// edge, so the near side lands left of the slot.
double coverArtLeadingOffset(double coverWidth) {
  if (coverWidth <= 0) return 0;
  final cosine = math.cos(nowPlayingCoverTilt);
  final sine = math.sin(nowPlayingCoverTilt);
  final localX = -coverWidth;
  final rotatedX = cosine * localX;
  final rotatedZ = -sine * localX;
  final w = 1 + nowPlayingCoverPerspective * rotatedZ;
  if (w.abs() < 1e-6) return 0;
  return rotatedX / w + coverWidth;
}

/// Slide of an already-added title and artist between the two edges.
const Duration addedSongAlignDuration = Duration(milliseconds: 320);

class LcdScreen extends StatefulWidget {
  final PodTheme theme;

  const LcdScreen({super.key, required this.theme});

  @override
  State<LcdScreen> createState() => _LcdScreenState();
}

class _LcdScreenState extends State<LcdScreen> {
  final ScrollController _scrollController = ScrollController();
  String? _trackedScreenId;
  int? _anchoredIndex;

  /// Settled slide position for add-to-playlist rows, so a recycled row does
  /// not replay the move. Cleared when that screen is left.
  final Map<String, double> _addSongShift = {};
  String? _addSongScreen;

  /// Single-line menus at depth 1–2 (home, Music, Settings, and the
  /// artist / album directories). Deeper track lists do not use these.
  static const double _menuTitleSize = 13.5;
  static const double _menuRowHeight = 32 * _menuTitleSize / 12.5;

  /// Two-line track lists at depth 3+ (Songs, and an artist or album's tracks).
  static const double _songTitleSize = 15;
  static const double _songSubtitleSize = 12;
  static const double _songRowHeight = 52.5;
  static const double _meterSideSlot = 42;
  static const double _meterLabelGap = 4;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToIndex(
    String screenId,
    int index,
    int totalItems, {
    required double itemHeight,
  }) {
    if (!_scrollController.hasClients || totalItems == 0) return;
    final position = _scrollController.position;
    if (_trackedScreenId != screenId) {
      _trackedScreenId = screenId;
      _anchoredIndex = null;
      if (position.pixels != 0) {
        _scrollController.jumpTo(0);
      }
    }
    final target = EdgeScroll.targetOffset(
      index: index,
      previousIndex: _anchoredIndex,
      itemHeight: itemHeight,
      viewport: position.viewportDimension,
      currentOffset: _scrollController.position.pixels,
      maxOffset: position.maxScrollExtent,
    );
    _anchoredIndex = index;
    if ((target - _scrollController.position.pixels).abs() < 0.5) return;
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 80),
      curve: Curves.linear,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pod = context.watch<PodState>();
    final screen = pod.currentScreen;
    final selectedIdx = pod.currentSelectedIndex;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToIndex(
        screen.id,
        selectedIdx,
        screen.items.length,
        itemHeight: screen.useTwoLineRows ? _songRowHeight : _menuRowHeight,
      );
    });

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: widget.theme.lcdHeaderBorder, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6.5),
        child: Container(
          color: widget.theme.lcdBackground,
          child: Stack(
            children: [
              Column(
                children: [
                  _buildStatusBar(pod),
                  Expanded(
                    child: _buildScreenContent(
                      context,
                      pod,
                      screen,
                      selectedIdx,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _lightStatusMetal =>
      widget.theme.lcdHeaderStart.computeLuminance() > 0.45;

  List<Shadow> _engravedShadows() {
    if (_lightStatusMetal) {
      return const [
        Shadow(color: Color(0xF2FFFFFF), offset: Offset(0, 1), blurRadius: 0),
        Shadow(
          color: Color(0x42000000),
          offset: Offset(0, -0.7),
          blurRadius: 0.3,
        ),
      ];
    }
    return const [
      Shadow(color: Color(0xCC000000), offset: Offset(0, -1), blurRadius: 0.2),
      Shadow(color: Color(0x38FFFFFF), offset: Offset(0, 1), blurRadius: 0),
    ];
  }

  /// Light lip under dark metal type, dark lip above light type: pressed in.
  Widget _engravedGlyph(Widget child) {
    final lip = _lightStatusMetal
        ? const Color(0xE6FFFFFF)
        : const Color(0x99000000);
    final offset = _lightStatusMetal ? const Offset(0, 1) : const Offset(0, -1);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Transform.translate(
          offset: offset,
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(lip, BlendMode.srcIn),
            child: child,
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildStatusBar(PodState pod) {
    final engraved = _engravedShadows();
    return Container(
      height: 24,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6.5)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [widget.theme.lcdHeaderStart, widget.theme.lcdHeaderEnd],
        ),
        border: Border(
          bottom: BorderSide(color: widget.theme.lcdHeaderBorder, width: 1.0),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              pod.currentScreen.title,
              textAlign: TextAlign.left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.theme.lcdHeaderText,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
                shadows: engraved,
              ),
            ),
          ),
          _StatusClock(color: widget.theme.lcdHeaderText, shadows: engraved),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (pod.outputSnapshot.bluetoothConnected) ...[
                  _engravedGlyph(const BluetoothMark()),
                  const SizedBox(width: 5),
                ],
                if (pod.hasActivePlayback) ...[
                  _engravedGlyph(_buildPlaybackGlyph(pod.isPlaying)),
                  const SizedBox(width: 6),
                ],
                _engravedGlyph(_buildBatteryWidget(pod)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackGlyph(bool playing) {
    if (!playing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _glassPill(3.2, 10),
          const SizedBox(width: 2),
          _glassPill(3.2, 10),
        ],
      );
    }
    return const ClipPath(
      clipper: _PlayTriangleClipper(),
      child: SizedBox(
        width: 11,
        height: 11,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: ClassicGlass.progressFill),
        ),
      ),
    );
  }

  Widget _glassPill(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: ClassicGlass.progressFill,
        borderRadius: BorderRadius.circular(0.8),
      ),
    );
  }

  Widget _buildBatteryWidget(PodState pod) {
    final level = pod.batteryLevel.clamp(0, 100) / 100.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 23,
          height: 11,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: const Color(0xFF2E6E40), width: 1),
          ),
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: level,
                heightFactor: 1,
                child: const DecoratedBox(
                  decoration: BoxDecoration(gradient: ClassicGlass.batteryFill),
                ),
              ),
            ),
          ),
        ),
        Container(
          width: 2,
          height: 5,
          margin: const EdgeInsets.only(left: 0.6),
          decoration: const BoxDecoration(
            gradient: ClassicGlass.batteryFill,
            borderRadius: BorderRadius.horizontal(right: Radius.circular(1)),
          ),
        ),
      ],
    );
  }

  Widget _buildScreenContent(
    BuildContext context,
    PodState pod,
    PodMenuScreen screen,
    int selectedIdx,
  ) {
    if (screen.id == 'now_playing_view') {
      return _buildNowPlayingView(pod);
    }
    if (screen.id == 'about_view') {
      return _buildAboutView(pod, screen, selectedIdx);
    }
    if (screen.id == 'cover_flow_view') {
      return _buildCoverFlowView(pod);
    }
    if (screen.id == 'playlist_name') {
      return Column(
        children: [
          _PlaylistNameField(
            token: pod.playlistNameToken,
            initial: pod.playlistDraft,
            textColor: widget.theme.lcdText,
            hintColor: widget.theme.lcdSubtext,
            onChanged: pod.setPlaylistDraft,
            onSubmit: pod.commitPlaylistName,
          ),
          Expanded(child: _buildMenuList(pod, screen, selectedIdx)),
        ],
      );
    }

    if (screen.isSplitView) {
      return Row(
        children: [
          Expanded(flex: 9, child: _buildMenuList(pod, screen, selectedIdx)),
          Container(width: 1, color: widget.theme.lcdDivider),
          // Preview takes a little over half the row.
          Expanded(
            flex: 11,
            child: _buildDynamicPreview(pod, screen, selectedIdx),
          ),
        ],
      );
    }

    return _buildMenuList(pod, screen, selectedIdx);
  }

  Widget _buildMenuList(PodState pod, PodMenuScreen screen, int selectedIdx) {
    final twoLine = screen.useTwoLineRows;
    final itemHeight = twoLine ? _songRowHeight : _menuRowHeight;
    final slideAdded = screen.id.startsWith('playlist_add:');
    if (!slideAdded) {
      _addSongShift.clear();
      _addSongScreen = null;
    } else if (_addSongScreen != screen.id) {
      _addSongShift.clear();
      _addSongScreen = screen.id;
    }

    final listView = ListView.builder(
      controller: _scrollController,
      itemCount: screen.items.length,
      itemExtent: itemHeight,
      padding: EdgeInsets.zero,
      itemBuilder: (context, index) {
        final item = screen.items[index];
        final isSelected = index == selectedIdx;

        return GestureDetector(
          onTap: () {
            if (index == selectedIdx) {
              pod.onSelect();
            } else {
              pod.setSelectedIndex(index);
            }
          },
          child: Container(
            key: ValueKey(item.id),
            decoration: BoxDecoration(
              gradient: isSelected ? ClassicGlass.fill : null,
              color: isSelected
                  ? null
                  : item.alreadyAdded
                  ? addedSongRowColor
                  : (index.isEven
                        ? Colors.transparent
                        : widget.theme.lcdDivider.withValues(alpha: 0.15)),
              border: twoLine && index < screen.items.length - 1
                  ? const Border(
                      bottom: BorderSide(color: Color(0xFFB5B5BE), width: 1),
                    )
                  : null,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: twoLine ? 4 : 0,
            ),
            alignment: twoLine ? Alignment.centerLeft : null,
            child: twoLine
                ? _buildTwoLineRow(item, isSelected, slideAdded: slideAdded)
                : _buildSingleLineRow(
                    item,
                    isSelected,
                    heiti: screen.id == 'main' || screen.id == 'music',
                  ),
          ),
        );
      },
    );

    // Thin scrollbar on the right for long lists (e.g. Songs).
    return RawScrollbar(
      controller: _scrollController,
      thickness: 2.5,
      radius: const Radius.circular(1.5),
      thumbVisibility: screen.items.length > 6,
      thumbColor: widget.theme.lcdSubtext.withValues(alpha: 0.55),
      trackVisibility: false,
      child: listView,
    );
  }

  Widget _buildSingleLineRow(
    PodMenuItem item,
    bool isSelected, {
    bool heiti = false,
  }) {
    final titleWeight = heiti
        ? FontWeight.w900
        : (isSelected ? FontWeight.w700 : FontWeight.w500);
    return Row(
      children: [
        Expanded(
          child: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected
                  ? ClassicGlass.selectedText
                  : widget.theme.lcdText,
              fontSize: _menuTitleSize,
              fontWeight: titleWeight,
              fontFamily: heiti ? 'NotoSansSC' : null,
              fontVariations: heiti ? const [FontVariation('wght', 900)] : null,
            ),
          ),
        ),
        if (item.subtitle != null) ...[
          const SizedBox(width: 4),
          Text(
            item.subtitle!,
            style: TextStyle(
              color: isSelected
                  ? ClassicGlass.selectedText.withValues(alpha: 0.88)
                  : widget.theme.lcdSubtext,
              fontSize: 12,
            ),
          ),
        ],
        if (item.hasSubmenu) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 17,
            color: isSelected
                ? ClassicGlass.selectedText
                : widget.theme.lcdSubtext,
          ),
        ],
      ],
    );
  }

  Widget _buildTwoLineRow(
    PodMenuItem item,
    bool isSelected, {
    required bool slideAdded,
  }) {
    final titleStyle = TextStyle(
      color: isSelected ? ClassicGlass.selectedText : widget.theme.lcdText,
      fontSize: _songTitleSize,
      fontWeight: isSelected || item.alreadyAdded
          ? FontWeight.w700
          : FontWeight.w600,
      height: 1.12,
    );
    final subtitleStyle = TextStyle(
      color: isSelected
          ? ClassicGlass.selectedText.withValues(alpha: 0.92)
          : widget.theme.lcdSubtext,
      fontSize: _songSubtitleSize,
      fontWeight: item.alreadyAdded ? FontWeight.w700 : FontWeight.w500,
      height: 1.12,
    );
    Widget line(String text, TextStyle style) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final title = line(item.title, titleStyle);
    final subtitle = item.subtitle == null
        ? null
        : line(item.subtitle!, subtitleStyle);
    if (!slideAdded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [title, ?subtitle],
      );
    }
    return _AddSongShift(
      id: item.id,
      alignRight: item.alreadyAdded,
      memory: _addSongShift,
      title: title,
      subtitle: subtitle,
    );
  }

  Widget _buildDynamicPreview(
    PodState pod,
    PodMenuScreen screen,
    int selectedIdx,
  ) {
    if (screen.items.isEmpty) return const SizedBox();
    final item = screen.items[selectedIdx];
    final Uint8List? artBytes = pod.previewArtworkFor(item);

    final art = artBytes != null
        ? Image.memory(
            artBytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          )
        : _missingArtwork();
    final floats = screen.id == 'main' || screen.id == 'music';

    return ClipRect(
      child: ColoredBox(
        color: widget.theme.lcdBackground,
        child: floats ? _FloatingArtwork(child: art) : art,
      ),
    );
  }

  /// Light-blue square with a white music note for a missing cover.
  Widget _missingArtwork({double? size}) {
    final iconSize = size != null ? size * 0.42 : 56.0;
    final child = Container(
      color: const Color(0xFF8EBFDA),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        size: iconSize,
        color: Colors.white,
      ),
    );
    if (size != null) {
      return SizedBox(width: size, height: size, child: child);
    }
    return SizedBox.expand(child: child);
  }

  Widget _buildNowPlayingView(PodState pod) {
    return LayoutBuilder(
      builder: (context, window) {
        final midline = window.maxWidth / 2;
        const leftInset = 22.0;
        const rightInset = 12.0;
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 30),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Height is the old square size. Width is 16px less,
                    // so only the right edge moves left. The size still
                    // uses the 22px inset; the block's own left padding
                    // is whatever puts the tilted art on the first dot.
                    const pastMidline = 18.0;
                    const rightPull = 16.0;
                    final maxByHeight = constraints.maxHeight / 1.42;
                    var coverHeight = midline + pastMidline - leftInset;
                    if (coverHeight < 0) coverHeight = 0;
                    if (maxByHeight > 0 && coverHeight > maxByHeight) {
                      coverHeight = maxByHeight;
                    }
                    var coverWidth = coverHeight - rightPull;
                    if (coverWidth < 24) coverWidth = coverHeight;
                    final waveBottom = nowPlayingWaveBottom(
                      areaHeight: constraints.maxHeight,
                      coverHeight: coverHeight,
                    );
                    // The waveform keeps equal side margins. The cover
                    // block slides so the tilted art's left edge meets
                    // the first dot column.
                    const bandInset = 2.0;
                    final waveSide = (leftInset + rightInset) / 2 + bandInset;
                    final waveWidth = math.max(
                      0.0,
                      constraints.maxWidth - waveSide * 2,
                    );
                    final dotsLeft =
                        waveSide + waveformLeadingEdge(width: waveWidth);
                    final rawBlockLeft =
                        dotsLeft - coverArtLeadingOffset(coverWidth);
                    final maxBlockLeft = math.max(
                      0.0,
                      constraints.maxWidth - coverWidth - rightInset,
                    );
                    final blockLeft = rawBlockLeft.clamp(0.0, maxBlockLeft);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            left: blockLeft,
                            right: rightInset,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Transform.translate(
                                offset: const Offset(0, nowPlayingBlockDrop),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _build3DCoverArtwork(
                                      pod,
                                      coverWidth,
                                      coverHeight,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.start,
                                        children: [
                                          Text(
                                            pod.currentTitle,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: widget.theme.lcdText,
                                              fontSize: 16.5,
                                              fontWeight: FontWeight.w700,
                                              height: 1.2,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            pod.currentArtist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: widget.theme.lcdSubtext,
                                              fontSize: 14.0,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            pod.currentAlbum,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: widget.theme.lcdSubtext
                                                  .withValues(alpha: 0.8),
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            pod.queueLength > 0
                                                ? '${pod.queuePosition}/${pod.queueLength}  ${pod.playModeLabel}'
                                                : pod.playModeLabel,
                                            style: TextStyle(
                                              color: widget.theme.lcdSubtext,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: waveSide,
                          right: waveSide,
                          bottom: waveBottom,
                          child: NowPlayingWave(color: widget.theme.lcdText),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _buildBottomBar(pod),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(PodState pod) {
    Widget barWidget;
    if (pod.nowPlayingMode == NowPlayingSubMode.scrub) {
      barWidget = _buildScrubBar(pod);
    } else if (pod.nowPlayingMode == NowPlayingSubMode.rating) {
      barWidget = _buildRatingBar(pod);
    } else if (pod.isShowingVolume) {
      barWidget = _buildVolumeBar(pod);
    } else {
      barWidget = _buildProgressBar(pod);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: barWidget,
    );
  }

  Widget _buildProgressBar(PodState pod) {
    final rawRemaining =
        pod.currentDurationSeconds - pod.currentPositionSeconds;
    final remaining = rawRemaining < 0 ? 0 : rawRemaining;
    final timeStyle = TextStyle(
      color: widget.theme.lcdText,
      fontSize: 12,
      height: 1.0,
      fontWeight: FontWeight.w600,
    );
    return _buildMeterRow(
      key: const ValueKey('progress_bar'),
      factor: pod.playbackProgress.clamp(0.0, 1.0),
      leading: Text(
        _formatDuration(pod.currentPositionSeconds),
        style: timeStyle,
      ),
      trailing: Text(
        '-${_formatDuration(remaining)}',
        textAlign: TextAlign.right,
        style: timeStyle,
      ),
    );
  }

  Widget _buildVolumeBar(PodState pod) {
    final level = pod.volume.clamp(0.0, 1.0);
    final percent = (level * 100).round();
    final numberStyle = TextStyle(
      color: widget.theme.lcdText,
      fontSize: 12,
      height: 1.0,
      fontWeight: FontWeight.w700,
    );
    return Column(
      key: const ValueKey('volume_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$percent%', style: numberStyle),
        const SizedBox(height: 3),
        _buildMeterRow(
          key: const ValueKey('volume_meter'),
          factor: level,
          leading: Icon(
            Icons.volume_mute_rounded,
            size: 14,
            color: widget.theme.lcdSubtext,
          ),
          trailing: Icon(
            Icons.volume_up_rounded,
            size: 22,
            color: widget.theme.lcdSubtext,
          ),
        ),
      ],
    );
  }

  Widget _buildMeterRow({
    required Key key,
    required Widget leading,
    required Widget trailing,
    required double factor,
  }) {
    return Row(
      key: key,
      children: [
        SizedBox(
          width: _meterSideSlot,
          child: Align(alignment: Alignment.centerRight, child: leading),
        ),
        const SizedBox(width: _meterLabelGap),
        Expanded(child: _buildMeterBar(factor)),
        const SizedBox(width: _meterLabelGap),
        SizedBox(
          width: _meterSideSlot,
          child: Align(alignment: Alignment.centerLeft, child: trailing),
        ),
      ],
    );
  }

  Widget _buildMeterBar(double factor) {
    final clamped = factor.clamp(0.0, 1.0);
    return Container(
      height: 12,
      decoration: const BoxDecoration(color: Color(0xFFE4E8EE)),
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.hardEdge,
      child: FractionallySizedBox(
        widthFactor: clamped,
        child: const DecoratedBox(
          decoration: BoxDecoration(gradient: ClassicGlass.progressFill),
          child: Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              widthFactor: 0.92,
              child: Padding(
                padding: EdgeInsets.only(top: 1),
                child: SizedBox(
                  height: 2,
                  child: ColoredBox(color: Color(0xBFFFFFFF)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrubBar(PodState pod) {
    final double scrubProgress = pod.currentDurationSeconds > 0
        ? (pod.scrubPositionSeconds / pod.currentDurationSeconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;

    return Column(
      key: const ValueKey('scrub_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Scrub progress track with a diamond indicator
        LayoutBuilder(
          builder: (context, constraints) {
            final double barWidth = constraints.maxWidth;
            final double thumbX = (barWidth - 12.0) * scrubProgress;

            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                // Track bar
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE4E8EE),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: const Color(0xFFB4C2CE),
                      width: 0.6,
                    ),
                  ),
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.antiAlias,
                  child: FractionallySizedBox(
                    widthFactor: scrubProgress,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: ClassicGlass.fill),
                    ),
                  ),
                ),

                // Diamond scrubber knob
                Positioned(
                  left: thumbX,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: const Color(0xFF3AA6EA),
                        width: 2.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    transform: Matrix4.rotationZ(
                      0.785398,
                    ), // 45 degrees diamond
                    transformAlignment: Alignment.center,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(pod.scrubPositionSeconds),
              style: TextStyle(
                color: widget.theme.lcdHighlightStart,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.sync_rounded,
                  size: 11,
                  color: widget.theme.lcdHighlightStart,
                ),
                const SizedBox(width: 3),
                Text(
                  'Scrubbing',
                  style: TextStyle(
                    color: widget.theme.lcdHighlightStart,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            Text(
              '-${_formatDuration(pod.currentDurationSeconds - pod.scrubPositionSeconds)}',
              style: TextStyle(
                color: widget.theme.lcdHighlightStart,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRatingBar(PodState pod) {
    return Column(
      key: const ValueKey('rating_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (index) {
            final starNum = index + 1;
            final isRated = starNum <= pod.currentSongRating;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Icon(
                isRated ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 21,
                color: isRated
                    ? widget.theme.lcdHighlightStart
                    : widget.theme.lcdSubtext.withValues(alpha: 0.35),
              ),
            );
          }),
        ),
        const SizedBox(height: 3),
        Text(
          pod.currentSongRating > 0
              ? 'Rating: ${pod.currentSongRating} of 5 Stars'
              : 'Rotate Wheel to Rate',
          style: TextStyle(
            color: widget.theme.lcdSubtext,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumArtCard(
    PodState pod,
    double width,
    double height, {
    bool isReflection = false,
  }) {
    return Container(
      key: isReflection ? null : const Key('now_playing_cover'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: widget.theme.lcdDivider.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: widget.theme.lcdHeaderBorder.withValues(alpha: 0.7),
          width: 0.8,
        ),
        boxShadow: isReflection
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: pod.currentArtworkBytes != null
          ? Image.memory(
              pod.currentArtworkBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : _missingArtwork(size: height),
    );
  }

  Widget _build3DCoverArtwork(
    PodState pod,
    double coverWidth,
    double coverHeight,
  ) {
    const double reflectionFactor = 0.40;
    // 90% of the previous card, same aspect ratio. The slot keeps the old
    // top edge; the smaller card sits on that edge and is centered across
    // the old width, so it shrinks downward.
    const double scale = nowPlayingCoverScale;
    final cardWidth = coverWidth * scale;
    final cardHeight = coverHeight * scale;
    final slotHeight = coverHeight + 1 + coverHeight * reflectionFactor;

    final art = Transform(
      alignment: Alignment.centerRight,
      transform: Matrix4.identity()
        ..setEntry(3, 2, nowPlayingCoverPerspective)
        ..rotateY(nowPlayingCoverTilt),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAlbumArtCard(pod, cardWidth, cardHeight, isReflection: false),
          Container(
            width: cardWidth,
            height: 1,
            color: const Color(0x14000000),
          ),
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: reflectionFactor,
              child: _fadedMirror(
                visibleFactor: reflectionFactor,
                child: _buildAlbumArtCard(
                  pod,
                  cardWidth,
                  cardHeight,
                  isReflection: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return SizedBox(
      width: coverWidth,
      height: slotHeight,
      child: Align(alignment: Alignment.topCenter, child: art),
    );
  }

  /// Mirrored artwork that is strong at the contact line and gone before the clip.
  Widget _fadedMirror({required double visibleFactor, required Widget child}) {
    final mid = (visibleFactor * 0.32).clamp(0.04, 0.45);
    final end = (visibleFactor * 0.82).clamp(mid + 0.02, 0.96);
    return Transform.flip(
      flipY: true,
      child: ShaderMask(
        shaderCallback: (rect) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [
              Color(0xE0FFFFFF),
              Color(0x55FFFFFF),
              Color(0x00FFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: [0.0, mid, end, 1.0],
          ).createShader(rect);
        },
        blendMode: BlendMode.dstIn,
        child: child,
      ),
    );
  }

  Widget _buildAboutView(PodState pod, PodMenuScreen screen, int selectedIdx) {
    final infoStyle = TextStyle(color: widget.theme.lcdSubtext, fontSize: 11);
    final lineStyle = TextStyle(color: widget.theme.lcdText, fontSize: 11);
    return Center(
      child: Column(
        key: const Key('about_content'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            child: Column(
              children: [
                Image.asset(
                  'assets/brand/likepod.png',
                  key: const Key('about_app_icon'),
                  width: 32,
                  height: 32,
                  filterQuality: FilterQuality.medium,
                ),
                const SizedBox(height: 4),
                Text(
                  'LikePod',
                  style: TextStyle(
                    color: widget.theme.lcdText,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                // 版本号经 package_info_plus 读自 pubspec,永不脱钩。
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version;
                    if (version == null) return const SizedBox.shrink();
                    return Text('Version $version', style: infoStyle);
                  },
                ),
                const SizedBox(height: 6),
                Text('作者：Kimonmusic', style: lineStyle),
                Text('复古滚轮播放器', style: infoStyle),
              ],
            ),
          ),
          SizedBox(
            height: _menuRowHeight,
            child: _buildMenuList(pod, screen, selectedIdx),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverFlowView(PodState pod) {
    if (pod.albums.isEmpty) {
      return _buildEmptyCoverFlow();
    }

    final currentIndex = pod.coverFlowIndex.clamp(0, pod.albums.length - 1);
    final currentAlbum = pod.albums[currentIndex];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -120) {
            pod.onRotate(1);
          } else if (details.primaryVelocity! > 120) {
            pod.onRotate(-1);
          }
        }
      },
      child: Container(
        color: const Color(0xFFF7F7F8),
        child: Column(
          children: [
            Expanded(
              child: _AnimatedCoverFlow(
                albums: pod.albums,
                index: currentIndex,
                onRotate: pod.onRotate,
                onSelect: pod.onSelect,
                buildCard: _buildCoverFlowCardWithReflection,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                bottom: 8,
                left: 16,
                right: 16,
                top: 0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    currentAlbum.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    currentAlbum.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF6E6E6E),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCoverFlow() {
    return const ColoredBox(
      color: Color(0xFFF7F7F8),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No Albums',
              style: TextStyle(
                color: Color(0xFF1A1A1A),
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 4),
            Text(
              '音乐 > 播放列表 > 重新扫描',
              style: TextStyle(color: Color(0xFF6E6E6E), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverFlowCardWithReflection(
    AlbumModel album,
    double cardSize,
    double reflectionFactor, {
    required double spine,
    required bool spineOnRight,
  }) {
    final spineOpacity = spine.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: cardSize,
          height: cardSize,
          child: Stack(
            children: [
              _buildAlbumArtCardForModel(album, cardSize, isReflection: false),
              if (spineOpacity > 0.02)
                Positioned(
                  left: spineOnRight ? null : 0,
                  right: spineOnRight ? 0 : null,
                  top: 0,
                  bottom: 0,
                  width: 11,
                  child: Opacity(
                    opacity: spineOpacity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: spineOnRight
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                          end: spineOnRight
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          colors: const [
                            Color(0x66FFFFFF),
                            Color(0xFFF4FBFF),
                            Color(0xFFD7E7F2),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(width: cardSize, height: 1, color: const Color(0x18000000)),
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: reflectionFactor,
            child: _fadedMirror(
              visibleFactor: reflectionFactor,
              child: _buildAlbumArtCardForModel(
                album,
                cardSize,
                isReflection: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumArtCardForModel(
    AlbumModel album,
    double size, {
    bool isReflection = false,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: widget.theme.lcdDivider.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: const Color(0xFFD5D5D8), width: 0.6),
        boxShadow: isReflection
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: album.artworkBytes != null
          ? Image.memory(
              album.artworkBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : _missingArtwork(size: size),
    );
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _AnimatedCoverFlow extends StatefulWidget {
  final List<AlbumModel> albums;
  final int index;
  final void Function(int step) onRotate;
  final VoidCallback onSelect;
  final Widget Function(
    AlbumModel album,
    double cardSize,
    double reflectionFactor, {
    required double spine,
    required bool spineOnRight,
  })
  buildCard;

  const _AnimatedCoverFlow({
    required this.albums,
    required this.index,
    required this.onRotate,
    required this.onSelect,
    required this.buildCard,
  });

  @override
  State<_AnimatedCoverFlow> createState() => _AnimatedCoverFlowState();
}

class _AnimatedCoverFlowState extends State<_AnimatedCoverFlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _from = 0;
  double _to = 0;

  double get _visual {
    final t = Curves.easeInOut.transform(_controller.value);
    return _from + (_to - _from) * t;
  }

  @override
  void initState() {
    super.initState();
    _from = _to = widget.index.toDouble();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedCoverFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.index.toDouble();
    if ((next - _to).abs() < 0.001) return;
    _from = _visual;
    _to = next;
    final distance = (_to - _from).abs();
    final ms = (240 + 80 * distance).round().clamp(240, 560);
    _controller.duration = Duration(milliseconds: ms);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            const reflectionFactor = 0.42;
            final cardSize = (constraints.maxHeight * 0.52).clamp(112.0, 142.0);
            final centerX = constraints.maxWidth / 2;
            final stackHeight = cardSize * (1 + reflectionFactor);
            final top = ((constraints.maxHeight - stackHeight) / 2).clamp(
              0.0,
              80.0,
            );
            final visual = _visual;
            final count = widget.albums.length;
            if (count == 0 || constraints.maxWidth <= 0) {
              return const SizedBox.shrink();
            }

            final base = visual.round().clamp(0, count - 1);
            var minIdx = (base - 4).clamp(0, count - 1);
            var maxIdx = (base + 4).clamp(0, count - 1);
            final fromI = _from.round().clamp(0, count - 1);
            final toI = _to.round().clamp(0, count - 1);
            if (fromI < minIdx) minIdx = fromI;
            if (toI < minIdx) minIdx = toI;
            if (fromI > maxIdx) maxIdx = fromI;
            if (toI > maxIdx) maxIdx = toI;

            final indices = [for (var i = minIdx; i <= maxIdx; i++) i];
            indices.sort(
              (a, b) => (b - visual).abs().compareTo((a - visual).abs()),
            );

            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final idx in indices)
                  _positionedCard(
                    idx: idx,
                    visual: visual,
                    cardSize: cardSize,
                    centerX: centerX,
                    top: top,
                    reflectionFactor: reflectionFactor,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _positionedCard({
    required int idx,
    required double visual,
    required double cardSize,
    required double centerX,
    required double top,
    required double reflectionFactor,
  }) {
    final delta = idx - visual;
    final pose = CoverFlowPose.at(
      delta: delta,
      cardSize: cardSize,
      centerX: centerX,
    );
    return Positioned(
      left: pose.left,
      top: top,
      child: GestureDetector(
        onTap: () {
          if (delta.abs() < 0.35 && widget.index == idx) {
            widget.onSelect();
          } else {
            widget.onRotate(idx - widget.index);
          }
        },
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0016)
            ..rotateY(pose.rotY),
          child: widget.buildCard(
            widget.albums[idx],
            cardSize,
            reflectionFactor,
            spine: pose.spine,
            spineOnRight: delta < 0,
          ),
        ),
      ),
    );
  }
}

class _FloatingArtwork extends StatefulWidget {
  final Widget child;

  const _FloatingArtwork({required this.child});

  @override
  State<_FloatingArtwork> createState() => _FloatingArtworkState();
}

class _FloatingArtworkState extends State<_FloatingArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value * math.pi * 2;
        final dx = math.sin(t) * 11 + math.sin(t * 2 + 0.6) * 3;
        final dy = math.sin(t + 1.3) * 2.2;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: 1.08, child: child),
        );
      },
    );
  }
}

class _StatusClock extends StatefulWidget {
  final Color color;
  final List<Shadow> shadows;

  const _StatusClock({required this.color, required this.shadows});

  @override
  State<_StatusClock> createState() => _StatusClockState();
}

class _StatusClockState extends State<_StatusClock> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = DateTime.now();
      if (next.hour != _now.hour || next.minute != _now.minute) {
        setState(() => _now = next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hour = _now.hour.toString().padLeft(2, '0');
    final minute = _now.minute.toString().padLeft(2, '0');
    return Text(
      '$hour:$minute',
      style: TextStyle(
        color: widget.color,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        fontFeatures: const [FontFeature.tabularFigures()],
        shadows: widget.shadows,
      ),
    );
  }
}

class _PlayTriangleClipper extends CustomClipper<Path> {
  const _PlayTriangleClipper();

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width * 0.12, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(size.width * 0.12, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _PlaylistNameField extends StatefulWidget {
  final int token;
  final String initial;
  final Color textColor;
  final Color hintColor;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  const _PlaylistNameField({
    required this.token,
    required this.initial,
    required this.textColor,
    required this.hintColor,
    required this.onChanged,
    required this.onSubmit,
  });

  @override
  State<_PlaylistNameField> createState() => _PlaylistNameFieldState();
}

class _PlaylistNameFieldState extends State<_PlaylistNameField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void didUpdateWidget(covariant _PlaylistNameField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.token != oldWidget.token && _controller.text != widget.initial) {
      _controller.text = widget.initial;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: TextField(
        controller: _controller,
        autofocus: true,
        cursorColor: ClassicGlass.progressBlue,
        style: TextStyle(
          color: widget.textColor,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          isDense: true,
          hintText: '播放列表名称',
          hintStyle: TextStyle(color: widget.hintColor, fontSize: 15),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: InputBorder.none,
        ),
        onChanged: widget.onChanged,
        onSubmitted: (_) => widget.onSubmit(),
      ),
    );
  }
}

/// Slides the title and artist between the left and right edges.
class _AddSongShift extends StatefulWidget {
  final String id;
  final bool alignRight;
  final Map<String, double> memory;
  final Widget title;
  final Widget? subtitle;

  const _AddSongShift({
    required this.id,
    required this.alignRight,
    required this.memory,
    required this.title,
    required this.subtitle,
  });

  @override
  State<_AddSongShift> createState() => _AddSongShiftState();
}

class _AddSongShiftState extends State<_AddSongShift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late double _from;
  late double _to;

  double get _t {
    final curved = Curves.easeOutCubic.transform(_controller.value);
    return _from + (_to - _from) * curved;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: addedSongAlignDuration,
    );
    final target = widget.alignRight ? 1.0 : 0.0;
    final known = widget.memory[widget.id];
    _from = known ?? 0;
    _to = target;
    if (_from == _to) {
      _controller.value = 1;
      widget.memory[widget.id] = _to;
    } else {
      _controller.forward().whenComplete(_remember);
    }
  }

  @override
  void didUpdateWidget(covariant _AddSongShift oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.alignRight ? 1.0 : 0.0;
    if (widget.id != oldWidget.id) {
      _from = widget.memory[widget.id] ?? 0;
      _to = target;
      if (_from == _to) {
        _controller.value = 1;
        widget.memory[widget.id] = _to;
      } else {
        _controller.forward(from: 0).whenComplete(_remember);
      }
      return;
    }
    if (target == _to) return;
    _from = _t;
    _to = target;
    _controller.forward(from: 0).whenComplete(_remember);
  }

  void _remember() {
    if (!mounted) return;
    widget.memory[widget.id] = _to;
  }

  @override
  void dispose() {
    widget.memory[widget.id] = _t;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _placed(widget.title),
            if (widget.subtitle != null) _placed(widget.subtitle!),
          ],
        );
      },
    );
  }

  Widget _placed(Widget child) {
    return Align(alignment: Alignment(-1 + 2 * _t, 0), child: child);
  }
}
