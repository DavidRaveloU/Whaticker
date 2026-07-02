import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:stikerz/core/constants/app_colors.dart';
import 'package:stikerz/core/extensions/localization_extension.dart';
import 'package:stikerz/core/providers/update_provider.dart';
import 'package:stikerz/core/repositories/pack_repository.dart';
import 'package:stikerz/core/services/ads_service.dart';
import 'package:stikerz/core/services/sticker_generation_service.dart';
import 'package:stikerz/core/utils/responsive_text.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/aspect_ratio_selector.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/editor_controls.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/editor_timeline.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/editor_top_bar.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/editor_video_area.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/fullscreen_crop_page.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/generate_confirm_dialog.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/generation_failure_modal.dart';
import 'package:stikerz/ui/features/sticker_editor/presentation/widgets/video_prefetcher.dart';

class StickerEditorPage extends ConsumerStatefulWidget {
  final int packId;
  final int slotIndex;
  final String sourceType;
  final String? videoPath;
  final bool skipVideoInitialization;

  const StickerEditorPage({
    super.key,
    required this.packId,
    required this.slotIndex,
    required this.sourceType,
    this.videoPath,
    this.skipVideoInitialization = false,
  });

  @override
  ConsumerState<StickerEditorPage> createState() => _StickerEditorPageState();
}

class _StickerEditorPageState extends ConsumerState<StickerEditorPage>
    with TickerProviderStateMixin {
  late final Player _player;
  late final VideoController _videoController;
  late final VideoPrefetcher _prefetcher;

  bool _videoReady = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isGenerating = false;
  String _generationStatus = '';
  double? _generationProgress;
  bool _isMuted = true;

  // Local editor state.
  AspectRatioOption _aspectRatio = AspectRatioOption.square;
  double _startPoint = 0.0;
  double _duration = 5.0;
  double _playheadPosition = 0.0;
  double _videoDurationSecs = 1.0;
  Offset _cropOffset = const Offset(0.08, 0.10);
  double _cropWidth = 0.76;
  double _videoAspect = 1.0;

  late AnimationController _playheadCtrl;
  StreamSubscription<Duration>? _positionSub;
  int _lastPositionMs = -1;
  DateTime _lastPosSeen = DateTime.now();
  // Native player cache seconds used as an approximation for buffered amount
  final double _cacheSecs = 15.0;
  double? _bufferedFraction;

  @override
  void initState() {
    super.initState();

    if (!widget.skipVideoInitialization) {
      _player = Player();
      _videoController = VideoController(_player);
      _prefetcher = VideoPrefetcher(() => _bufferedFraction ?? 0.0);
    }

    _playheadCtrl =
        AnimationController(
            vsync: this,
            duration: Duration(seconds: _duration.round()),
          )
          ..addListener(() {
            if (!_isGenerating) {
              setState(() {
                _playheadPosition =
                    _startPoint +
                    _playheadCtrl.value * (_duration / _videoDurationSecs);
              });
            }
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && _isPlaying) {
              _restartLoopPreviewFromStart();
            }
          });

    if (!widget.skipVideoInitialization) {
      _initVideo();
    }
  }

  Future<void> _initVideo({bool useHwdec = true}) async {
    final path = widget.videoPath;
    try {
      if (path == null || path.trim().isEmpty) {
        throw const FormatException('Empty video path');
      }

      // Apply network-friendly player options for remote streams.
      if (path.startsWith('http') && useHwdec) {
        try {
          final nativePlayer = _player.platform as NativePlayer;
          await nativePlayer.setProperty('hwdec', 'mediacodec');
          await nativePlayer.setProperty('hwdec-codecs', 'all');
          await nativePlayer.setProperty('cache', 'yes');
          await nativePlayer.setProperty('cache-secs', '15');
        } catch (e) {
          if (kDebugMode) debugPrint('Failed to set native properties: $e');
        }
      }

      await _player.open(Media(path), play: false);
      await _player.setVolume(_isMuted ? 0 : 100);
      bool videoInitialized = false;

      _player.stream.duration.first.then((dur) {
        if (!mounted || videoInitialized) return;
        setState(() {
          _videoDurationSecs = dur.inMilliseconds > 0
              ? dur.inMilliseconds / 1000.0
              : 1.0;
          _syncDurationToWindow();
        });
      });

      // Keep display aspect ratio in sync with rotation-aware video params.
      _player.stream.videoParams.listen((params) {
        if (!mounted) return;
        final resolved = _resolveAspectFromParams(params);
        if (resolved != null && resolved > 0) {
          setState(() {
            _videoAspect = resolved;
            final n = _normalizeCrop(_cropOffset, _cropWidth, _aspectRatio);
            _cropOffset = n.$1;
            _cropWidth = n.$2;
          });
        }
      });

      _player.stream.completed.listen((_) {
        if (_isPlaying && mounted) {
          _restartLoopPreviewFromStart();
        }
      });

      // Wait up to 8s for either video params or valid duration.
      try {
        await Future.any([
          _player.stream.videoParams.firstWhere(
            (p) => (p.w ?? p.dw) != null && (p.h ?? p.dh) != null,
          ),
          _player.stream.duration.firstWhere((d) => d.inMilliseconds > 500),
        ]).timeout(const Duration(seconds: 8));
      } catch (_) {
        if (kDebugMode) debugPrint('Timeout waiting for video initialization');
      }

      if (!mounted) return;
      setState(() => _videoReady = true);

      // Start listening to position updates to detect stalls/buffering.
      _positionSub = _player.stream.position.listen((pos) {
        if (!mounted) return;
        final ms = pos.inMilliseconds;

        if (_isPlaying) {
          if (ms == _lastPositionMs) {
            // position not advancing
            if (DateTime.now().difference(_lastPosSeen) >
                const Duration(milliseconds: 800)) {
              if (!_isBuffering) {
                setState(() => _isBuffering = true);
                // pause playback while buffering to avoid audio-only experience
                _player.pause();
                // stop the playhead animation so timeline stops moving
                try {
                  _playheadCtrl.stop();
                } catch (_) {}
              }
            }
          } else {
            // position advanced
            _lastPositionMs = ms;
            _lastPosSeen = DateTime.now();
            // sync playhead with actual player position for accurate timeline
            final posSecs = ms / 1000.0;
            setState(() {
              _playheadPosition = (posSecs / _videoDurationSecs).clamp(
                0.0,
                1.0,
              );
              _bufferedFraction = ((posSecs + _cacheSecs) / _videoDurationSecs)
                  .clamp(0.0, 1.0);
            });
            if (_isBuffering) {
              // resume playback when progress resumes
              _player.play();
              setState(() => _isBuffering = false);
              // resume playhead animation from current value
              try {
                if (!_playheadCtrl.isAnimating) {
                  _playheadCtrl.forward();
                }
              } catch (_) {}
            }
          }
        } else {
          _lastPositionMs = ms;
          _lastPosSeen = DateTime.now();
        }
      });

      await _player.play();
      if (!mounted) return;
      setState(() => _isPlaying = true);
      _playheadCtrl.forward(from: 0);
    } catch (e) {
      if (kDebugMode) debugPrint('Error initializing video editor: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.videoOpenError(e))));
      Navigator.pop(context);
    }
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    _player.setVolume(_isMuted ? 0 : 100);
  }

  Future<void> _restartLoopPreviewFromStart() async {
    final ms = (_startPoint * _videoDurationSecs * 1000).round();
    await _player.seek(Duration(milliseconds: ms));

    if (!mounted) return;
    setState(() => _playheadPosition = _startPoint);

    _playheadCtrl.stop();

    // Wait for estimated buffered fraction to cover the target start.
    final targetFraction = _startPoint.clamp(0.0, 1.0);
    final buffered = await _prefetcher.waitForBuffered(
      targetFraction,
      timeout: const Duration(seconds: 8),
    );

    if (_isPlaying && buffered) {
      await _player.play();
      _playheadCtrl.forward(from: 0);
    } else if (_isPlaying && !buffered) {
      // still not buffered: show buffering state and keep paused until
      // the position stream detects progress and resumes playback.
      setState(() => _isBuffering = true);
    }
  }

  /// Resolves display aspect ratio using rotation-aware video metadata.
  ///
  /// Many phone videos are stored in landscape dimensions with a 90/270
  /// rotation tag. We transpose width and height when needed so crop and
  /// preview geometry match what users actually see.
  double? _resolveAspectFromParams(VideoParams params) {
    final baseW = params.dw ?? params.w;
    final baseH = params.dh ?? params.h;

    if (baseW == null || baseH == null || baseW <= 0 || baseH <= 0) {
      return null;
    }

    // Rotation is reported in degrees (0, 90, 180, 270).
    // 90/270 means rendered dimensions are transposed.
    final rotation = params.rotate ?? 0;
    final isTransposed = rotation == 90 || rotation == 270;

    final displayW = isTransposed ? baseH : baseW;
    final displayH = isTransposed ? baseW : baseH;

    return displayW / displayH;
  }

  void _syncDurationToWindow() {
    final maxDur = _maxDurationForCurrentStart;
    if (_duration > maxDur) _duration = maxDur;
    _playheadCtrl.duration = Duration(milliseconds: (_duration * 1000).round());
  }

  double get _maxDurationForCurrentStart {
    final remaining = _videoDurationSecs - (_startPoint * _videoDurationSecs);
    return math.min(5.0, remaining.clamp(0.1, 5.0));
  }

  void _togglePlay() async {
    // If currently buffering, avoid trying to play until buffer resumes.
    if (!_isPlaying && _isBuffering) {
      // show buffering state and don't start playhead
      setState(() => _isPlaying = false);
      return;
    }

    setState(() => _isPlaying = !_isPlaying);

    if (_isPlaying) {
      await _player.play();
      // start playhead animation only when not buffering
      if (!_isBuffering) {
        _playheadCtrl.forward();
      }
    } else {
      await _player.pause();
      _playheadCtrl.stop();
    }
  }

  void _setAspectRatio(AspectRatioOption ratio) {
    setState(() {
      _aspectRatio = ratio;
      final n = _normalizeCrop(_cropOffset, _cropWidth, ratio);
      _cropOffset = n.$1;
      _cropWidth = n.$2;
    });
  }

  (Offset, double) _normalizeCrop(
    Offset rawOffset,
    double rawWidth,
    AspectRatioOption ratio,
  ) {
    final safeAspect = _videoAspect > 0 ? _videoAspect : 1.0;
    double safeWidth = rawWidth.clamp(0.15, 1.0);
    double safeHeight = (safeWidth * safeAspect) / ratio.ratio;

    if (safeHeight > 1.0) {
      safeHeight = 1.0;
      safeWidth = (safeHeight * ratio.ratio / safeAspect).clamp(0.15, 1.0);
    }

    final maxDx = (1.0 - safeWidth).clamp(0.0, 1.0);
    final maxDy = (1.0 - safeHeight).clamp(0.0, 1.0);

    final safeOffset = Offset(
      rawOffset.dx.clamp(0.0, maxDx),
      rawOffset.dy.clamp(0.0, maxDy),
    );

    return (safeOffset, safeWidth);
  }

  void _updateCrop(Offset offset, double width) {
    final n = _normalizeCrop(offset, width, _aspectRatio);
    setState(() {
      _cropOffset = n.$1;
      _cropWidth = n.$2;
    });
  }

  Future<void> _openFullscreenCrop() async {
    final result = await Navigator.of(context).push<(Offset, double)>(
      MaterialPageRoute(
        builder: (_) => FullscreenCropPage(
          videoController: _videoController,
          initialOffset: _cropOffset,
          initialCropWidth: _cropWidth,
          aspectRatio: _aspectRatio,
          videoAspect: _videoAspect,
        ),
        fullscreenDialog: true,
      ),
    );

    if (result == null || !mounted) return;

    final n = _normalizeCrop(result.$1, result.$2, _aspectRatio);
    setState(() {
      _cropOffset = n.$1;
      _cropWidth = n.$2;
    });
  }

  void _showGenerateConfirm() {
    showDialog(
      context: context,
      builder: (dialogContext) => GenerateConfirmDialog(
        aspectRatio: _aspectRatio,
        startSecs: _startPoint * _videoDurationSecs,
        durationSecs: _duration,
        onCancel: () => Navigator.of(dialogContext).pop(),
        onConfirm: () {
          Navigator.of(dialogContext).pop();
          _generateSticker();
        },
      ),
    );
  }

  /// Shows an interstitial when available, then pops with `generated`.
  Future<void> _popWithAd() async {
    await AdsService().showInterstitialAd(
      onDismissed: () {
        if (mounted) {
          Navigator.pop(context, 'generated');
          // Después de volver, verificar actualizaciones
          _checkForUpdateAfterAction();
        }
      },
    );
  }

  void _checkForUpdateAfterAction() {
    // Esperar a que la navegación se complete
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        ref.read(silentUpdateCheckProvider);
        if (ref.read(updateAvailableProvider)) {
          ref.read(updateServiceProvider).showUpdateIfAvailable();
        }
      }
    });
  }

  Future<void> _generateSticker() async {
    if (_isPlaying) {
      await _player.pause();
      _playheadCtrl.stop();
      setState(() => _isPlaying = false);
    }

    setState(() {
      _isGenerating = true;
      _generationStatus = context.l10n.preparingVideo;
      _generationProgress = 0.0;
    });

    try {
      final result = await StickerGenerationService.generate(
        StickerGenerationRequest(
          inputPath: widget.videoPath!,
          packId: widget.packId,
          slotIndex: widget.slotIndex,
          startSec: _startPoint * _videoDurationSecs,
          durationSec: _duration,
          cropX: _cropOffset.dx,
          cropY: _cropOffset.dy,
          cropWidth: _cropWidth,
          cropHeight: (_cropWidth * _videoAspect) / _aspectRatio.ratio,
          requiresInternet: widget.sourceType == 'tiktok',
          aspectRatioLabel: _aspectRatio.label,
        ),
        strategy: 'none',
        onStatus: (status, progress) {
          if (!mounted) return;
          setState(() {
            _generationStatus = status;
            _generationProgress = progress;
          });
        },
      );

      if (result.success && result.path != null) {
        await PackRepository.instance.addSticker(
          packId: widget.packId,
          slotIndex: widget.slotIndex,
          webpPath: result.path!,
          sourceType: widget.sourceType,
        );

        if (!mounted) return;
        await _popWithAd();
      } else {
        if (!mounted) return;
        _showFailureModal(retry: true, failedSize: result.failedSize);
      }
    } catch (e) {
      if (!mounted) return;
      _showFailureModal(retry: false, failedSize: null);
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _generationStatus = '';
          _generationProgress = null;
        });
      }
    }
  }

  @override
  void dispose() {
    if (!widget.skipVideoInitialization) {
      _player.dispose();
      _positionSub?.cancel();
    }
    _playheadCtrl.dispose();
    _checkForUpdateAfterAction();
    super.dispose();
  }

  void _showFailureModal({bool retry = false, int? failedSize}) {
    showDialog(
      context: context,
      builder: (dialogContext) => GenerationFailureModal(
        canRetry: retry,
        failedSizeBytes: failedSize,
        onRetryWithBlur: () =>
            _retryWith(StickerStrategy.lightBlur, dialogContext),
        onRetryWithReduceFps: () =>
            _retryWith(StickerStrategy.reduceFps, dialogContext),
        onRetryWithBlurAndReduceFps: () =>
            _retryWith(StickerStrategy.blurAndReduceFps, dialogContext),
        onRetryWithTransparency: () =>
            _retryWith(StickerStrategy.increaseTransparency, dialogContext),
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  void _retryWith(StickerStrategy strategy, BuildContext dialogContext) {
    Navigator.of(dialogContext).pop();
    _generateStickerWithStrategy(strategy);
  }

  Future<void> _generateStickerWithStrategy(StickerStrategy strategy) async {
    if (!mounted) return;

    setState(() {
      _isGenerating = true;
      _generationStatus = context.l10n.preparingVideo;
      _generationProgress = 0.0;
    });

    try {
      final result = await StickerGenerationService.generate(
        StickerGenerationRequest(
          inputPath: widget.videoPath!,
          packId: widget.packId,
          slotIndex: widget.slotIndex,
          startSec: _startPoint * _videoDurationSecs,
          durationSec: _duration,
          cropX: _cropOffset.dx,
          cropY: _cropOffset.dy,
          cropWidth: _cropWidth,
          cropHeight: (_cropWidth * _videoAspect) / _aspectRatio.ratio,
          requiresInternet: widget.sourceType == 'tiktok',
          aspectRatioLabel: _aspectRatio.label,
        ),
        strategy: strategy.name,
        onStatus: (status, progress) {
          if (!mounted) return;
          setState(() {
            _generationStatus = status;
            _generationProgress = progress;
          });
        },
      );

      if (!mounted) return;

      if (result.success && result.path != null) {
        await PackRepository.instance.addSticker(
          packId: widget.packId,
          slotIndex: widget.slotIndex,
          webpPath: result.path!,
          sourceType: widget.sourceType,
        );

        if (!mounted) return;
        setState(() {
          _isGenerating = false;
          _generationStatus = '';
          _generationProgress = null;
        });
        await _popWithAd();
      } else {
        if (!mounted) return;
        setState(() {
          _isGenerating = false;
          _generationStatus = '';
          _generationProgress = null;
        });
        _showFailureModal(retry: true, failedSize: result.failedSize);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        _generationStatus = '';
        _generationProgress = null;
      });
      _showFailureModal(retry: false, failedSize: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.skipVideoInitialization) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: _buildLoadingArea(context),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            EditorTopBar(
              selectedAspect: _aspectRatio,
              onAspectChanged: _setAspectRatio,
              onBack: () => Navigator.pop(context),
            ),
            Expanded(
              child: widget.skipVideoInitialization
                  ? _buildLoadingArea(context)
                  : IgnorePointer(
                      ignoring: _isGenerating,
                      child: EditorVideoArea(
                        videoController: _videoController,
                        videoReady: _videoReady,
                        isBuffering: _isBuffering,
                        thumbnailPath: null,
                        cropOffset: _cropOffset,
                        cropWidth: _cropWidth,
                        aspectRatio: _aspectRatio,
                        videoAspect: _videoAspect,
                        onCropChanged: _updateCrop,
                        onTogglePlay: _togglePlay,
                        isPlaying: _isPlaying,
                        isMuted: _isMuted,
                        onToggleMute: _toggleMute,
                        onOpenFullscreenCrop: _openFullscreenCrop,
                      ),
                    ),
            ),
            EditorTimeline(
              startPoint: _startPoint,
              duration: _duration,
              playheadPosition: _playheadPosition,
              videoDurationSecs: _videoDurationSecs,
              bufferedFraction: _bufferedFraction,
            ),
            EditorControls(
              startPoint: _startPoint,
              duration: _duration,
              videoDurationSecs: _videoDurationSecs,
              isGenerating: _isGenerating,
              generationStatus: _generationStatus,
              generationProgress: _generationProgress,
              aspectRatio: _aspectRatio,
              onAspectChanged: _setAspectRatio,
              onStartPointChanged: (v) {
                setState(() {
                  _startPoint = v;
                  _syncDurationToWindow();
                  _playheadPosition = _startPoint;
                });
                _restartLoopPreviewFromStart();
              },
              onDurationChanged: (v) {
                setState(() {
                  _duration = v.clamp(0.1, _maxDurationForCurrentStart);
                  _playheadCtrl.duration = Duration(
                    milliseconds: (_duration * 1000).round(),
                  );
                  _playheadPosition = _startPoint;
                });
                _restartLoopPreviewFromStart();
              },
              onGenerate: _showGenerateConfirm,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingArea(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: context.responsiveSize(36, tabletSize: 40),
              height: context.responsiveSize(36, tabletSize: 40),
              child: const CircularProgressIndicator(
                value: 0.72,
                color: AppColors.accent,
                strokeWidth: 3.5,
              ),
            ),
            SizedBox(height: context.responsiveSize(20, tabletSize: 24)),
            Text(
              context.l10n.loadingVideo,
              style: context.responsiveTextStyle(
                mobileSize: 16,
                tabletSize: 18,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: context.responsiveSize(6, tabletSize: 8)),
            Text(
              context.l10n.instagramLoadingNote,
              style: context.responsiveTextStyle(
                mobileSize: 13,
                tabletSize: 14,
                color: AppColors.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
