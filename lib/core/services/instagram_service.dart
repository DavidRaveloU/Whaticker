// ignore_for_file: constant_identifier_names

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'remote_provider_config.dart';

class InstagramResult {
  final String? videoUrl;
  final String? error;

  const InstagramResult({this.videoUrl, this.error});

  bool get success => videoUrl != null && error == null;
  bool get hasError => error != null;
}

class InstagramService {
  static const String errExternal = 'err_external_service';
  static const String errTimeout = 'err_timeout';
  static const String errInvalidResponse = 'err_invalid_response';
  static const String errNotVideo = 'err_not_a_video';
  static const String errVideoNotPublic = 'err_video_not_public';

  static final RemoteResolverService _resolver = RemoteResolverService(
    configUrl:
        'https://gist.githubusercontent.com/DavidRaveloU/f4d1c9c28667589d524b2a6262d142cd/raw/instagram_providers.json',
    cacheKey: 'instagram_providers_cache',
  );

  static String? cleanInstagramUrl(String rawInput) {
    if (rawInput.trim().isEmpty) return null;
    final regex = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:reel|p|tv)/[^\s]+',
      caseSensitive: false,
    );
    final match = regex.firstMatch(rawInput);
    if (match == null) return null;
    return _stripTrailingPunctuation(match.group(0)!);
  }

  static String _stripTrailingPunctuation(String value) {
    var out = value.trim();
    while (out.isNotEmpty && '.!,?)]'.contains(out[out.length - 1])) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static bool isValidInstagramUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return false;
    if (!uri.host.toLowerCase().contains('instagram.com')) return false;
    return ['/reel/', '/p/', '/tv/'].any((p) => uri.path.contains(p));
  }

  static Future<bool> hasInternet() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  static Future<InstagramResult> getVideoUrl(String instagramUrl) async {
    if (!isValidInstagramUrl(instagramUrl)) {
      return const InstagramResult(error: errInvalidResponse);
    }

    if (!await hasInternet()) {
      return const InstagramResult(error: errExternal);
    }

    final providers = await _resolver.loadProviders();

    if (providers.isEmpty) {
      if (kDebugMode) debugPrint('[InstagramService] ⚠️ No providers loaded');
      return const InstagramResult(error: errExternal);
    }

    for (final provider in providers) {
      final videoUrl = await _resolver.execute(provider, instagramUrl);
      if (videoUrl != null) {
        if (kDebugMode) {
          debugPrint('[InstagramService] ✅ RESOLVED VIA: ${provider.name}');
        }
        return InstagramResult(videoUrl: videoUrl);
      }
      if (kDebugMode) {
        debugPrint('[InstagramService] ❌ ${provider.name} failed');
      }
    }

    if (kDebugMode) debugPrint('[InstagramService] ⚠️ All providers failed');
    return const InstagramResult(error: errExternal);
  }
}
