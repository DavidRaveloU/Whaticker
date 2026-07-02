import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stikerz/core/constants/app_colors.dart';
import 'package:stikerz/core/extensions/localization_extension.dart';
import 'package:stikerz/core/providers/update_provider.dart';
import 'package:stikerz/core/repositories/pack_repository.dart';
import 'package:stikerz/core/services/ads_service.dart';
import 'package:stikerz/core/services/image_processing_isolates.dart';
import 'package:stikerz/core/services/static_sticker_generation_service.dart';
import 'package:stikerz/core/utils/image_cache_utils.dart'; // <--- NUEVO IMPORT (1)
import 'package:stikerz/generated_l10n/app_localizations.dart';
import 'package:stikerz/ui/features/image_editor/presentation/models/crop_type.dart';
import 'package:stikerz/ui/features/image_editor/presentation/providers/crop_provider.dart';
import 'package:stikerz/ui/features/image_editor/presentation/providers/image_editor_provider.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/crop_overlay_painter.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/crop_toolbar.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/free_form_crop_painter.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/generate_button.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/image_preview.dart';
import 'package:stikerz/ui/features/image_editor/presentation/widgets/magnifier.dart';

/// Page for editing static images to create stickers.
class ImageEditorPage extends ConsumerStatefulWidget {
  final int packId;
  final int slotIndex;
  final String imagePath;

  const ImageEditorPage({
    super.key,
    required this.packId,
    required this.slotIndex,
    required this.imagePath,
  });

  @override
  ConsumerState<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends ConsumerState<ImageEditorPage>
    with TickerProviderStateMixin {
  bool _imageLoaded = false;
  late final ImageEditorNotifier _editorNotifier;

  @override
  void initState() {
    super.initState();
    _editorNotifier = ref.read(imageEditorProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(imageEditorProvider.notifier).resetCropState();
      }
    });
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(imageEditorProvider.notifier).resetCropState();
        }
      });

      final bytes = await File(widget.imagePath).readAsBytes();
      final aspect = await compute(extractImageAspectInIsolate, bytes);
      if (!mounted) return;

      final currentState = ref.read(imageEditorProvider);
      final normalized = CropProvider.normalizeCrop(
        rawOffset: currentState.cropOffset,
        rawWidth: currentState.cropWidth,
        imageAspect: aspect,
        aspectRatio: 1.0,
      );

      final notifier = ref.read(imageEditorProvider.notifier);
      notifier.setImageAspect(aspect);
      notifier.updateCrop(normalized.$1, normalized.$2);

      setState(() {
        _imageLoaded = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${context.l10n.error}: $e')));
        Navigator.pop(context);
      }
    }
  }

  void _openFullscreenEditor() async {
    final state = ref.read(imageEditorProvider);

    // Guard adicional: aunque el botón ya está deshabilitado en la UI
    // cuando no se puede usar pantalla completa, evitamos abrir la
    // pantalla completa si por alguna razón se invoca igual (p.ej. taps
    // en cola mientras el estado cambiaba).
    if (!state.canUseFullscreen) return;

    final result = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => _FullscreenImageCropPage(
          imagePath: widget.imagePath,
          initialOffset: state.cropOffset,
          initialCropWidth: state.cropWidth,
          imageAspect: state.imageAspect,
          cropType: state.selectedCrop,
          freeFormPoints: state.freeFormPoints,
          smartCropPreviewPath: state.smartCropPreviewPath,
        ),
        fullscreenDialog: true,
      ),
    );

    if (result == null || !mounted) return;

    final notifier = ref.read(imageEditorProvider.notifier);

    if (result is List<ui.Offset>) {
      notifier.syncFromFullscreen(
        freeFormPoints: result,
        cropType: CropType.freeForm,
      );
      return;
    }

    if (result is (Offset, double)) {
      notifier.syncFromFullscreen(cropOffset: result.$1, cropWidth: result.$2);
      return;
    }
  }

  Future<void> _generateSticker() async {
    final state = ref.read(imageEditorProvider);
    final notifier = ref.read(imageEditorProvider.notifier);

    if (!_imageLoaded) return;
    if (state.isGenerating) return;

    notifier.setGenerating(
      generating: true,
      status: context.l10n.processingImage,
      progress: 0.0,
    );

    try {
      double normX, normY, normW, normH;
      bool useCircularMask;
      List<ui.Offset>? freeFormPoints;

      switch (state.selectedCrop) {
        case CropType.square:
          normX = state.cropOffset.dx;
          normY = state.cropOffset.dy;
          normW = state.cropWidth;
          normH = state.cropHeight;
          useCircularMask = false;
          freeFormPoints = null;
          break;
        case CropType.circle:
          normX = state.cropOffset.dx;
          normY = state.cropOffset.dy;
          normW = state.cropWidth;
          normH = state.cropHeight;
          useCircularMask = true;
          freeFormPoints = null;
          break;
        case CropType.freeForm:
          if (state.freeFormPoints.length < 3) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.l10n.imageEditorTraceShapeFirst),
                ),
              );
            }
            notifier.resetGenerationState();
            return;
          }
          normX = 0.0;
          normY = 0.0;
          normW = 1.0;
          normH = 1.0;
          useCircularMask = false;
          freeFormPoints = state.freeFormPoints;
          break;
        case CropType.smart:
          if (state.smartCropPreviewPath == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    context.l10n.smartCropNoSubjectDetectedGenerate,
                  ),
                ),
              );
            }
            notifier.resetGenerationState();
            return;
          }
          // Para smart usamos la imagen pre-procesada con fondo transparente
          // y pasamos toda la imagen (sin recorte adicional).
          // Cambiamos inputImagePath al preview y usamos crop completo.
          final smartResult = await StaticStickerGenerationService.generate(
            inputImagePath: state.smartCropPreviewPath!,
            packId: widget.packId,
            slotIndex: widget.slotIndex,
            normalizedCropX: 0.0,
            normalizedCropY: 0.0,
            normalizedCropWidth: 1.0,
            normalizedCropHeight: 1.0,
            useCircularMask: false,
            freeFormPoints: null,
            smartSubjectMode: true,
            rotationDegrees: 0.0,
            onStatus: (status, progress) {
              if (mounted) {
                notifier.setGenerating(
                  generating: true,
                  status: status,
                  progress: progress,
                );
              }
            },
          );

          if (!mounted) return;

          if (smartResult.success && smartResult.path != null) {
            await PackRepository.instance.addSticker(
              packId: widget.packId,
              slotIndex: widget.slotIndex,
              webpPath: smartResult.path!,
              sourceType: 'image_gallery',
            );
            if (mounted) await _popWithAd();
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    smartResult.error ?? context.l10n.imageEditorCouldNotCreate,
                  ),
                ),
              );
            }
          }
          return;
      }

      final result = await StaticStickerGenerationService.generate(
        inputImagePath: widget.imagePath,
        packId: widget.packId,
        slotIndex: widget.slotIndex,
        normalizedCropX: normX,
        normalizedCropY: normY,
        normalizedCropWidth: normW,
        normalizedCropHeight: normH,
        useCircularMask: useCircularMask,
        freeFormPoints: freeFormPoints,
        rotationDegrees: 0.0,
        onStatus: (status, progress) {
          if (mounted) {
            notifier.setGenerating(
              generating: true,
              status: status,
              progress: progress,
            );
          }
        },
      );

      if (!mounted) return;

      if (result.success && result.path != null) {
        await PackRepository.instance.addSticker(
          packId: widget.packId,
          slotIndex: widget.slotIndex,
          webpPath: result.path!,
          sourceType: 'image_gallery',
        );
        if (mounted) await _popWithAd();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.error ?? context.l10n.imageEditorCouldNotCreate,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${context.l10n.error}: $e')));
      }
    } finally {
      if (mounted) {
        notifier.resetGenerationState();
      }
    }
  }

  Future<void> _popWithAd() async {
    await AdsService().showInterstitialAd(
      onDismissed: () {
        if (mounted) {
          Navigator.pop(context, 'generated');
          _checkForUpdateAfterAction();
        }
      },
    );
  }

  void _checkForUpdateAfterAction() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        ref.read(silentUpdateCheckProvider);
        if (ref.read(updateAvailableProvider)) {
          ref.read(updateServiceProvider).showUpdateIfAvailable();
        }
      }
    });
  }

  @override
  void dispose() {
    // Si el usuario sale de la página mientras el recorte automático
    // (ML Kit) sigue procesando en segundo plano, invalidamos esa
    // solicitud: el resultado tardío se ignorará gracias al token, sin
    // necesidad (ni posibilidad real) de cancelar el trabajo ya en curso.
    _editorNotifier.cancelActiveSmartCropRequest();
    _checkForUpdateAfterAction();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(imageEditorProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: !state.isGenerating,
        child: IgnorePointer(
          ignoring: state.isGenerating,
          child: Scaffold(
            backgroundColor: AppColors.background,
            appBar: _buildAppBar(state),
            body: _buildBody(state),
            bottomNavigationBar: _imageLoaded
                ? GenerateButton(
                    onPressed: state.isGenerating ? null : _generateSticker,
                  )
                : null,
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ImageEditorState state) {
    return AppBar(
      backgroundColor: AppColors.background,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded, color: Colors.white),
        onPressed: state.isGenerating ? null : () => Navigator.pop(context),
      ),
      title: Text(
        context.l10n.imageEditorTitle,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      actions: [
        if (state.isGenerating)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: state.generationProgress,
                color: AppColors.accent,
                strokeWidth: 2,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBody(ImageEditorState state) {
    if (!_imageLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }

    return Column(
      children: [
        CropToolbar(
          imagePath: widget.imagePath,
          onFullscreenTap: _openFullscreenEditor,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final areaSize = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              return ImagePreview(
                imagePath: widget.imagePath,
                areaSize: areaSize,
              );
            },
          ),
        ),
        if (state.isGenerating && state.generationStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              state.generationStatus,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════ FullscreenImageCropPage ═══════════════════

class _FullscreenImageCropPage extends StatefulWidget {
  final String imagePath;
  final Offset initialOffset;
  final double initialCropWidth;
  final double imageAspect;
  final CropType cropType;
  final List<ui.Offset> freeFormPoints;

  /// Ruta al PNG pre-procesado del smart cutout. Solo relevante cuando
  /// [cropType] es [CropType.smart]; en ese caso se muestra esta imagen
  /// en lugar de la original, sin caja de recorte ajustable.
  final String? smartCropPreviewPath;

  const _FullscreenImageCropPage({
    required this.imagePath,
    required this.initialOffset,
    required this.initialCropWidth,
    required this.imageAspect,
    required this.cropType,
    required this.freeFormPoints,
    this.smartCropPreviewPath,
  });

  @override
  State<_FullscreenImageCropPage> createState() =>
      _FullscreenImageCropPageState();
}

class _FullscreenImageCropPageState extends State<_FullscreenImageCropPage> {
  late Offset _cropOffset;
  late double _cropWidth;
  late List<ui.Offset> _freeFormPoints;

  @override
  void initState() {
    super.initState();
    _cropOffset = widget.initialOffset;
    _cropWidth = widget.initialCropWidth;
    _freeFormPoints = List.from(widget.freeFormPoints);
  }

  double get _height => (_cropWidth * widget.imageAspect) / 1.0;

  void _updateCrop(Offset o, double w) {
    const a = 1.0;
    final sa = widget.imageAspect > 0 ? widget.imageAspect : 1.0;
    double sw = w.clamp(0.15, 1.0);
    double sh = (sw * sa) / a;
    if (sh > 1.0) {
      sh = 1.0;
      sw = (sh * a / sa).clamp(0.15, 1.0);
    }
    final mx = (1.0 - sw).clamp(0.0, 1.0);
    final my = (1.0 - sh).clamp(0.0, 1.0);
    setState(() {
      _cropOffset = Offset(o.dx.clamp(0, mx), o.dy.clamp(0, my));
      _cropWidth = sw;
    });
  }

  Rect _calcRect(Size area) {
    final a = widget.imageAspect;
    return area.width / area.height > a
        ? Rect.fromLTWH(
            (area.width - area.height * a) / 2,
            0,
            area.height * a,
            area.height,
          )
        : Rect.fromLTWH(
            0,
            (area.height - area.width / a) / 2,
            area.width,
            area.width / a,
          );
  }

  void _saveAndClose() {
    if (widget.cropType == CropType.freeForm) {
      Navigator.of(context).pop(_freeFormPoints);
    } else if (widget.cropType == CropType.smart) {
      // El recorte smart no tiene ajustes manuales (usa la imagen completa
      // pre-procesada), así que no hay nada que sincronizar de vuelta.
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pop((_cropOffset, _cropWidth));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFreeForm = widget.cropType == CropType.freeForm;
    final isSmart = widget.cropType == CropType.smart;
    final l10n = context.l10n;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(isFreeForm, isSmart, l10n),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    final area = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final imageRect = _calcRect(area);

                    if (isFreeForm) {
                      return _FullscreenFreeFormArea(
                        imagePath: widget.imagePath,
                        imageRect: imageRect,
                        areaSize: area,
                        freeFormPoints: _freeFormPoints,
                        onPointsChanged: (points) {
                          setState(() {
                            _freeFormPoints = points;
                          });
                        },
                      );
                    }

                    if (isSmart) {
                      return _buildSmartPreviewArea(imageRect);
                    }

                    return _buildSquareCircleArea(area, imageRect);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isFreeForm, bool isSmart, AppLocalizations l10n) {
    final String title;
    if (isFreeForm) {
      title = l10n.imageEditorTraceShape;
    } else if (isSmart) {
      title = l10n.smartCropPreviewTitle;
    } else {
      title = l10n.imageEditorAdjustCrop;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: _saveAndClose,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const SizedBox(width: 36),
        ],
      ),
    );
  }

  Widget _buildSquareCircleArea(Size area, Rect imageRect) {
    // CAMBIO (2a): antes eran dos líneas con _cacheDimensionPx separado
    // para width y height. Ahora se calculan juntos para no deformar
    // el aspect ratio decodificado.
    final (cacheWidth, cacheHeight) = cacheDimensionsPx(
      context,
      imageRect.width,
      imageRect.height,
    );
    final left = imageRect.left + (_cropOffset.dx * imageRect.width);
    final top = imageRect.top + (_cropOffset.dy * imageRect.height);
    final w = _cropWidth * imageRect.width;
    final h = _height * imageRect.height;

    return Stack(
      children: [
        Positioned.fromRect(
          rect: imageRect,
          child: Image.file(
            File(widget.imagePath),
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            filterQuality: FilterQuality.low,
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: CropOverlayPainter(
              cropRect: Rect.fromLTWH(left, top, w, h),
              isCircle: widget.cropType == CropType.circle,
            ),
          ),
        ),
        _ImageCropBox(
          offset: _cropOffset,
          cropWidth: _cropWidth,
          imageAspect: widget.imageAspect,
          imageRect: imageRect,
          onChanged: _updateCrop,
        ),
      ],
    );
  }

  /// Vista de solo-lectura del smart cutout: muestra la imagen ya
  /// pre-procesada (fondo transparente) sin ninguna caja de recorte,
  /// ya que en este modo no existe un recorte manual que ajustar.
  Widget _buildSmartPreviewArea(Rect imageRect) {
    final path = widget.smartCropPreviewPath ?? widget.imagePath;
    // CAMBIO (2b): mismo patrón que arriba.
    final (cacheWidth, cacheHeight) = cacheDimensionsPx(
      context,
      imageRect.width,
      imageRect.height,
    );

    return Stack(
      children: [
        Positioned.fromRect(
          rect: imageRect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════ FullscreenFreeFormArea ═══════════════════

class _FullscreenFreeFormArea extends StatefulWidget {
  final String imagePath;
  final Rect imageRect;
  final Size areaSize;
  final List<ui.Offset> freeFormPoints;
  final void Function(List<ui.Offset>) onPointsChanged;

  const _FullscreenFreeFormArea({
    required this.imagePath,
    required this.imageRect,
    required this.areaSize,
    required this.freeFormPoints,
    required this.onPointsChanged,
  });

  @override
  State<_FullscreenFreeFormArea> createState() =>
      _FullscreenFreeFormAreaState();
}

class _FullscreenFreeFormAreaState extends State<_FullscreenFreeFormArea> {
  late List<ui.Offset> _points;
  ui.Offset? _magnifierFocalPoint;

  @override
  void initState() {
    super.initState();
    _points = List.from(widget.freeFormPoints);
  }

  @override
  Widget build(BuildContext context) {
    final imageRect = widget.imageRect;
    // CAMBIO (2c): mismo patrón, esta es la vista de recorte libre en
    // pantalla completa — la que realmente usa la lupa, así que este
    // cambio también importa acá.
    final (cacheWidth, cacheHeight) = cacheDimensionsPx(
      context,
      imageRect.width,
      imageRect.height,
    );
    final l10n = context.l10n;

    return Stack(
      children: [
        Positioned.fromRect(
          rect: imageRect,
          child: Image.file(
            File(widget.imagePath),
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            filterQuality: FilterQuality.low,
          ),
        ),
        Positioned.fromRect(
          rect: imageRect,
          child: GestureDetector(
            onPanStart: (details) {
              final localPoint = details.localPosition;
              final clampedPoint = ui.Offset(
                localPoint.dx.clamp(0.0, imageRect.width),
                localPoint.dy.clamp(0.0, imageRect.height),
              );
              setState(() {
                _magnifierFocalPoint = clampedPoint;
                _points = [
                  ui.Offset(
                    clampedPoint.dx / imageRect.width,
                    clampedPoint.dy / imageRect.height,
                  ),
                ];
              });
              widget.onPointsChanged(_points);
            },
            onPanUpdate: (details) {
              final localPoint = details.localPosition;
              setState(() {
                _magnifierFocalPoint = ui.Offset(
                  localPoint.dx.clamp(0.0, imageRect.width),
                  localPoint.dy.clamp(0.0, imageRect.height),
                );
                _points.add(
                  ui.Offset(
                    (localPoint.dx / imageRect.width).clamp(0.0, 1.0),
                    (localPoint.dy / imageRect.height).clamp(0.0, 1.0),
                  ),
                );
              });
              widget.onPointsChanged(_points);
            },
            onPanEnd: (_) => setState(() {
              _magnifierFocalPoint = null;
            }),
            child: CustomPaint(
              size: Size(imageRect.width, imageRect.height),
              painter: FreeFormCropPainter(
                points: _points
                    .map(
                      (p) => ui.Offset(
                        p.dx * imageRect.width,
                        p.dy * imageRect.height,
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
        if (_points.isEmpty)
          Positioned.fill(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.imageEditorTraceOutline,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        if (_magnifierFocalPoint != null && _points.length > 5)
          MagnifierZoom(
            imagePath: widget.imagePath,
            imageRect: imageRect,
            areaSize: widget.areaSize,
            focalPoint: _magnifierFocalPoint!,
            tracePoints: _points,
          ),
      ],
    );
  }
}

// CAMBIO (3): se ELIMINÓ la función _cacheDimensionPx que estaba acá
// (la de una sola dimensión). Ya no se usa en este archivo — ahora se
// usa cacheDimensionsPx() importada de core/utils/image_cache_utils.dart.

// ═══════════════════ Internal ImageCropBox ═══════════════════

class _ImageCropBox extends StatefulWidget {
  final Offset offset;
  final double cropWidth;
  final double imageAspect;
  final Rect imageRect;
  final void Function(Offset offset, double width) onChanged;

  const _ImageCropBox({
    required this.offset,
    required this.cropWidth,
    required this.imageAspect,
    required this.imageRect,
    required this.onChanged,
  });

  @override
  State<_ImageCropBox> createState() => _ImageCropBoxState();
}

class _ImageCropBoxState extends State<_ImageCropBox> {
  Offset? _startOffset;
  Offset? _startFocalPoint;
  double? _startWidth;
  bool? _isScaling;

  double get _height => (widget.cropWidth * widget.imageAspect) / 1.0;

  @override
  Widget build(BuildContext context) {
    final vr = widget.imageRect;
    final left = vr.left + (widget.offset.dx * vr.width);
    final top = vr.top + (widget.offset.dy * vr.height);
    final w = widget.cropWidth * vr.width;
    final h = _height * vr.height;

    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: GestureDetector(
        onScaleStart: (details) {
          _startOffset = widget.offset;
          _startWidth = widget.cropWidth;
          _startFocalPoint = details.focalPoint;
          _isScaling = details.pointerCount >= 2;
        },
        onScaleUpdate: (details) {
          if (vr.width <= 0 || vr.height <= 0) return;
          if (_isScaling == false) {
            final startOff = _startOffset ?? widget.offset;
            final startF = _startFocalPoint ?? details.focalPoint;
            final delta = details.focalPoint - startF;
            widget.onChanged(
              Offset(
                startOff.dx + delta.dx / vr.width,
                startOff.dy + delta.dy / vr.height,
              ),
              widget.cropWidth,
            );
          } else {
            const sens = 0.2;
            final startW = _startWidth ?? widget.cropWidth;
            widget.onChanged(
              widget.offset,
              startW * (1 + (details.scale - 1) * sens),
            );
          }
        },
        onScaleEnd: (_) {
          _startOffset = null;
          _startWidth = null;
          _startFocalPoint = null;
          _isScaling = null;
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(color: Colors.transparent),
            _buildHandle(
              Offset(0, 0),
              1,
              left: left,
              top: top,
              w: w,
              h: h,
              vr: vr,
            ),
            _buildHandle(
              Offset(w, 0),
              2,
              left: left,
              top: top,
              w: w,
              h: h,
              vr: vr,
            ),
            _buildHandle(
              Offset(0, h),
              3,
              left: left,
              top: top,
              w: w,
              h: h,
              vr: vr,
            ),
            _buildHandle(
              Offset(w, h),
              4,
              left: left,
              top: top,
              w: w,
              h: h,
              vr: vr,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle(
    Offset position,
    int handle, {
    required double left,
    required double top,
    required double w,
    required double h,
    required Rect vr,
  }) {
    return Positioned(
      left: position.dx - 20,
      top: position.dy - 20,
      child: GestureDetector(
        onPanUpdate: (details) {
          if (vr.width <= 0) return;
          final deltaX = details.delta.dx / vr.width;
          double nw = widget.cropWidth,
              nox = widget.offset.dx,
              noy = widget.offset.dy;
          switch (handle) {
            case 1:
              nw = (widget.cropWidth - deltaX).clamp(0.15, 1.0);
              nox = widget.offset.dx + (widget.cropWidth - nw);
              noy =
                  widget.offset.dy +
                  (widget.cropWidth - nw) * (_height / widget.cropWidth);
              break;
            case 2:
              nw = (widget.cropWidth + deltaX).clamp(0.15, 1.0);
              nox = widget.offset.dx;
              noy =
                  widget.offset.dy -
                  (nw - widget.cropWidth) * (_height / widget.cropWidth);
              break;
            case 3:
              nw = (widget.cropWidth - deltaX).clamp(0.15, 1.0);
              nox = widget.offset.dx + (widget.cropWidth - nw);
              noy = widget.offset.dy;
              break;
            case 4:
              nw = (widget.cropWidth + deltaX).clamp(0.15, 1.0);
              nox = widget.offset.dx;
              noy = widget.offset.dy;
              break;
          }
          final newHeight = (nw * widget.imageAspect).clamp(0.0, 1.0);
          final mx = (1.0 - nw).clamp(0.0, 1.0);
          final my = (1.0 - newHeight).clamp(0.0, 1.0);
          widget.onChanged(Offset(nox.clamp(0, mx), noy.clamp(0, my)), nw);
        },
        child: Container(
          width: 40,
          height: 40,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
