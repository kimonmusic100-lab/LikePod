import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/album_model.dart';
import '../models/menu_item.dart';
import '../providers/pod_state.dart';
import '../services/music_service.dart';
import '../theme/pod_theme.dart';

class LcdScreen extends StatefulWidget {
  final PodTheme theme;

  const LcdScreen({
    super.key,
    required this.theme,
  });

  @override
  State<LcdScreen> createState() => _LcdScreenState();
}

class _LcdScreenState extends State<LcdScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToIndex(int index, int totalItems, {double itemHeight = 32.0}) {
    if (!_scrollController.hasClients || totalItems == 0) return;
    final targetOffset = (index * itemHeight) - (itemHeight * 2);
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pod = context.watch<PodState>();
    final screen = pod.currentScreen;
    final selectedIdx = pod.currentSelectedIndex;

    // Auto scroll list when wheel rotates
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToIndex(selectedIdx, screen.items.length, itemHeight: screen.useTwoLineRows ? 40.0 : 32.0);
    });

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(
          color: widget.theme.lcdHeaderBorder,
          width: 1.5,
        ),
        boxShadow: [
          // Inner display recess shadow
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
          child: Column(
            children: [
              // 1. Classic iPod Status Bar
              _buildStatusBar(pod),

              // 2. Screen Content (Split View or Full Screen)
              Expanded(
                child: _buildScreenContent(context, pod, screen, selectedIdx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar(PodState pod) {
    // Classic layout: title left; blue play/pause + battery on the right.
    const playBlue = Color(0xFF2BB0E8);

    return Container(
      height: 24,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6.5)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            widget.theme.lcdHeaderStart,
            widget.theme.lcdHeaderEnd,
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: widget.theme.lcdHeaderBorder,
            width: 1.0,
          ),
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
              ),
            ),
          ),
          if (pod.hasActivePlayback) ...[
            Icon(
              pod.isPlaying ? Icons.play_arrow : Icons.pause,
              size: 14,
              color: playBlue,
            ),
            const SizedBox(width: 6),
          ],
          _buildBatteryWidget(pod),
        ],
      ),
    );
  }

  Widget _buildBatteryWidget(PodState pod) {
    final level = pod.batteryLevel.clamp(0, 100);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 10,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: widget.theme.lcdBatteryBorder,
              width: 1.0,
            ),
          ),
          padding: const EdgeInsets.all(1.0),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: level / 100.0,
            child: Container(
              decoration: BoxDecoration(
                color: widget.theme.lcdBatteryFill,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
        Container(
          width: 1.5,
          height: 4,
          margin: const EdgeInsets.only(left: 0.5),
          decoration: BoxDecoration(
            color: widget.theme.lcdBatteryBorder,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(1),
              bottomRight: Radius.circular(1),
            ),
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
      return _buildAboutView(pod);
    }
    if (screen.id == 'cover_flow_view') {
      return _buildCoverFlowView(pod);
    }

    if (screen.isSplitView) {
      return Row(
        children: [
          // Left Column: Menu Items List
          Expanded(
            flex: 9,
            child: _buildMenuList(pod, screen, selectedIdx),
          ),
          // Vertical Divider
          Container(
            width: 1,
            color: widget.theme.lcdDivider,
          ),
          // Right Column: Dynamic Preview Window (~55% like Classic)
          Expanded(
            flex: 11,
            child: _buildDynamicPreview(pod, screen, selectedIdx),
          ),
        ],
      );
    }

    // Full width menu list
    return _buildMenuList(pod, screen, selectedIdx);
  }

  Widget _buildMenuList(PodState pod, PodMenuScreen screen, int selectedIdx) {
    final twoLine = screen.useTwoLineRows;
    final itemHeight = twoLine ? 40.0 : 32.0;

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
            decoration: isSelected
                ? BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        widget.theme.lcdHighlightStart,
                        widget.theme.lcdHighlightEnd,
                      ],
                    ),
                  )
                : BoxDecoration(
                    color: index.isEven
                        ? Colors.transparent
                        : widget.theme.lcdDivider.withValues(alpha: 0.15),
                    border: twoLine
                        ? Border(
                            bottom: BorderSide(
                              color: widget.theme.lcdDivider.withValues(alpha: 0.35),
                              width: 0.5,
                            ),
                          )
                        : null,
                  ),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: twoLine ? 3 : 0,
            ),
            alignment: twoLine ? Alignment.centerLeft : null,
            child: twoLine
                ? _buildTwoLineRow(item, isSelected)
                : _buildSingleLineRow(item, isSelected),
          ),
        );
      },
    );

    // Thin iPod-style scrollbar on the right for long lists (e.g. Songs).
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

  Widget _buildSingleLineRow(PodMenuItem item, bool isSelected) {
    return Row(
      children: [
        Expanded(
          child: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected
                  ? widget.theme.lcdHighlightText
                  : widget.theme.lcdText,
              fontSize: 12.5,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (item.subtitle != null) ...[
          const SizedBox(width: 4),
          Text(
            item.subtitle!,
            style: TextStyle(
              color: isSelected
                  ? widget.theme.lcdHighlightText.withValues(alpha: 0.8)
                  : widget.theme.lcdSubtext,
              fontSize: 11,
            ),
          ),
        ],
        if (item.hasSubmenu) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: isSelected
                ? widget.theme.lcdHighlightText
                : widget.theme.lcdSubtext,
          ),
        ],
      ],
    );
  }

  Widget _buildTwoLineRow(PodMenuItem item, bool isSelected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected
                ? widget.theme.lcdHighlightText
                : widget.theme.lcdText,
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            height: 1.1,
          ),
        ),
        if (item.subtitle != null)
          Text(
            item.subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected
                  ? widget.theme.lcdHighlightText.withValues(alpha: 0.85)
                  : widget.theme.lcdSubtext,
              fontSize: 10.5,
              fontWeight: FontWeight.w400,
              height: 1.15,
            ),
          ),
      ],
    );
  }
  Widget _buildDynamicPreview(PodState pod, PodMenuScreen screen, int selectedIdx) {
    if (screen.items.isEmpty) return const SizedBox();
    final item = screen.items[selectedIdx];
    final Uint8List? artBytes = pod.previewArtworkFor(item);

    // Classic iPod: artwork fills the entire right pane edge-to-edge.
    return ColoredBox(
      color: widget.theme.lcdBackground,
      child: artBytes != null
          ? Image.memory(
              artBytes,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            )
          : _buildIpodMissingArtwork(),
    );
  }

  /// Light-blue square with white music note (Classic empty-cover look).
  Widget _buildIpodMissingArtwork({double? size}) {
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 3D Perspective Trapezoid Album Art with Realistic Reflection, centered vertically
                _build3DCoverArtwork(pod),
                const SizedBox(width: 14),

                // Track Information (Refined authentic size)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
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
                          color: widget.theme.lcdSubtext.withValues(alpha: 0.8),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      if (pod.queueLength > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          '${pod.queuePosition}/${pod.queueLength}',
                          style: TextStyle(
                            color: widget.theme.lcdSubtext,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom Bar: Progress Bar or Volume Bar (overlapping)
          _buildBottomBar(pod),
        ],
      ),
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
    final rawRemaining = pod.currentDurationSeconds - pod.currentPositionSeconds;
    final remaining = rawRemaining < 0 ? 0 : rawRemaining;
    return Row(
      key: const ValueKey('progress_bar'),
      children: [
        SizedBox(
          width: 34,
          child: Text(
            _formatDuration(pod.currentPositionSeconds),
            style: TextStyle(
              color: widget.theme.lcdText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _buildIpodMeterBar(pod.playbackProgress.clamp(0.0, 1.0)),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 40,
          child: Text(
            '-${_formatDuration(remaining)}',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: widget.theme.lcdText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
  Widget _buildVolumeBar(PodState pod) {
    return Row(
      key: const ValueKey('volume_bar'),
      children: [
        Icon(
          Icons.volume_mute_rounded,
          size: 14,
          color: widget.theme.lcdSubtext,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _buildIpodMeterBar(pod.volume.clamp(0.0, 1.0)),
        ),
        const SizedBox(width: 6),
        Icon(
          Icons.volume_up_rounded,
          size: 22,
          color: widget.theme.lcdSubtext,
        ),
      ],
    );
  }

  Widget _buildIpodMeterBar(double factor) {
    return Container(
      height: 10,
      decoration: BoxDecoration(
        color: widget.theme.lcdDivider,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: widget.theme.lcdHeaderBorder.withValues(alpha: 0.45),
          width: 0.5,
        ),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: factor,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                widget.theme.lcdHighlightStart,
                widget.theme.lcdHighlightEnd,
              ],
            ),
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ),
    );
  }
  Widget _buildScrubBar(PodState pod) {
    final double scrubProgress = pod.currentDurationSeconds > 0
        ? (pod.scrubPositionSeconds / pod.currentDurationSeconds).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      key: const ValueKey('scrub_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Scrub progress track with authentic iPod diamond indicator
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
                  height: 9,
                  decoration: BoxDecoration(
                    color: widget.theme.lcdDivider,
                    borderRadius: BorderRadius.circular(4.5),
                    border: Border.all(
                      color: widget.theme.lcdHeaderBorder.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  ),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: scrubProgress,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            widget.theme.lcdHighlightStart,
                            widget.theme.lcdHighlightEnd,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(4.5),
                      ),
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
                        color: widget.theme.lcdHighlightStart,
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
                    transform: Matrix4.rotationZ(0.785398), // 45 degrees diamond
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

  Widget _buildAlbumArtCard(PodState pod, double size, {bool isReflection = false}) {
    return Container(
      width: size,
      height: size,
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
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 7,
                  offset: const Offset(3, 3),
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
          : _buildIpodMissingArtwork(size: size),
    );
  }

  Widget _build3DCoverArtwork(PodState pod) {
    const double coverSize = 112.0; // Perfectly balanced size
    const double reflectionFactor = 0.36;
    const double reflectionHeight = coverSize * reflectionFactor;

    // Shift down by reflectionHeight * 0.5 (~20px) so that the cover artwork
    // itself is exactly vertically centered, perfectly fixing the "偏上" issue!
    return Padding(
      padding: const EdgeInsets.only(top: reflectionHeight * 0.5),
      child: Transform(
        alignment: Alignment.centerLeft,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0024) // Perspective factor
          ..rotateY(-0.30)         // Negative Y angle: Left edge tall/forward, Right edge recedes small
          ..rotateX(0.04)          // Slight forward pitch for natural perspective view
          ..rotateZ(-0.01),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. The Main 3D Album Cover (Centered)
            _buildAlbumArtCard(pod, coverSize, isReflection: false),

            // 2. Refined Glass Floor Specular Horizon Line (Ground Contact)
            Container(
              width: coverSize,
              height: 1.0,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0x40000000),
                    Color(0x18000000),
                    Color(0x05000000),
                  ],
                ),
              ),
            ),

            // 3. Realistic Mirror Ground Reflection (Glassy exponential fade, no drop shadow)
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: reflectionFactor,
                child: Transform.flip(
                  flipY: true,
                  child: ShaderMask(
                    shaderCallback: (rect) {
                      return const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x66FFFFFF), // ~40% opacity at floor contact line
                          Color(0x28FFFFFF), // ~16% mid fade
                          Color(0x08FFFFFF), // ~3% subtle tail
                          Color(0x00FFFFFF), // 0% completely transparent
                        ],
                        stops: [0.0, 0.30, 0.65, 1.0],
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.dstIn,
                    child: _buildAlbumArtCard(pod, coverSize, isReflection: true),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutView(PodState pod) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.radio_rounded,
            size: 40,
            color: widget.theme.lcdHighlightStart,
          ),
          const SizedBox(height: 8),
          Text(
            'LikePod Classic',
            style: TextStyle(
              color: widget.theme.lcdText,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Version 1.0.0 (Phase 1)',
            style: TextStyle(
              color: widget.theme.lcdSubtext,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: widget.theme.lcdDivider.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Capacity: 160 GB • Format: Android FLAC/MP3',
              style: TextStyle(
                color: widget.theme.lcdSubtext,
                fontSize: 10,
              ),
            ),
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

    // Card dimensions
    const double cardSize = 112.0;
    const double reflectionFactor = 0.35;
    const double reflectionHeight = cardSize * reflectionFactor;

    // Visible range
    const int visibleRange = 3;
    final int minIdx = (currentIndex - visibleRange).clamp(0, pod.albums.length - 1);
    final int maxIdx = (currentIndex + visibleRange).clamp(0, pod.albums.length - 1);

    // Stacking order: left cards, right cards, center card on top
    final List<int> renderIndices = [];
    for (int i = minIdx; i < currentIndex; i++) {
      renderIndices.add(i);
    }
    for (int i = maxIdx; i > currentIndex; i--) {
      renderIndices.add(i);
    }
    renderIndices.add(currentIndex);

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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              widget.theme.lcdBackground,
              widget.theme.lcdBackground,
              const Color(0xFFF2F2F2),
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: Column(
          children: [
            // 3D Cover Flow Stage
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final centerX = constraints.maxWidth / 2;
                  final centerY = (constraints.maxHeight - reflectionHeight * 0.5) / 2;

                  return Stack(
                    clipBehavior: Clip.none,
                    children: renderIndices.map((idx) {
                      final album = pod.albums[idx];
                      final int offset = idx - currentIndex;
                      final bool isCenter = offset == 0;

                      double x;
                      double rotY;
                      double scale;
                      double dimAlpha;

                      if (isCenter) {
                        x = centerX - cardSize / 2;
                        rotY = 0.0;
                        scale = 1.0;
                        dimAlpha = 0.0;
                      } else if (offset < 0) {
                        // Left cards: perspective-tilted toward center
                        final double stepOffset = (offset + 1) * 28.0;
                        x = centerX - cardSize / 2 - 66.0 + stepOffset;
                        rotY = 0.92;
                        scale = 0.86;
                        dimAlpha = (0.12 + (-offset - 1) * 0.10).clamp(0.0, 0.45);
                      } else {
                        // Right cards: perspective-tilted toward center
                        final double stepOffset = (offset - 1) * 28.0;
                        x = centerX - cardSize / 2 + 66.0 + stepOffset;
                        rotY = -0.92;
                        scale = 0.86;
                        dimAlpha = (0.12 + (offset - 1) * 0.10).clamp(0.0, 0.45);
                      }

                      return Positioned(
                        left: x,
                        top: centerY - cardSize / 2,
                        child: GestureDetector(
                          onTap: () {
                            if (isCenter) {
                              pod.onSelect();
                            } else {
                              pod.onRotate(offset);
                            }
                          },
                          child: Transform(
                            alignment: const Alignment(0.0, 0.48),
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, 0.0024)
                              ..rotateY(rotY)
                              ..scaleByDouble(scale, scale, 1.0, 1.0),
                            child: Stack(
                              children: [
                                _buildCoverFlowCardWithReflection(
                                  album,
                                  cardSize,
                                  reflectionFactor,
                                ),
                                if (dimAlpha > 0)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: dimAlpha),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),

            // Album Metadata Info
            Container(
              padding: const EdgeInsets.only(bottom: 10, left: 18, right: 18, top: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    currentAlbum.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.theme.lcdText,
                      fontSize: 13.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    currentAlbum.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.theme.lcdSubtext,
                      fontSize: 11.0,
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildIpodMissingArtwork(size: 88),
          const SizedBox(height: 14),
          Text(
            'No Albums',
            style: TextStyle(
              color: widget.theme.lcdText,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Music > Playlists > Rescan',
            style: TextStyle(
              color: widget.theme.lcdSubtext,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverFlowCardWithReflection(
    AlbumModel album,
    double cardSize,
    double reflectionFactor,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Album Face
        _buildAlbumArtCardForModel(album, cardSize, isReflection: false),

        // 2. Ground horizon line
        Container(
          width: cardSize,
          height: 1.0,
          color: Colors.black.withValues(alpha: 0.15),
        ),

        // 3. Mirror Reflection
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: reflectionFactor,
            child: Transform.flip(
              flipY: true,
              child: ShaderMask(
                shaderCallback: (rect) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66FFFFFF),
                      Color(0x24FFFFFF),
                      Color(0x06FFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [0.0, 0.35, 0.7, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: _buildAlbumArtCardForModel(album, cardSize, isReflection: true),
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
        border: Border.all(
          color: widget.theme.lcdHeaderBorder.withValues(alpha: 0.7),
          width: 0.8,
        ),
        boxShadow: isReflection
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 6,
                  offset: const Offset(2, 2),
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
          : _buildIpodMissingArtwork(size: size),
    );
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
