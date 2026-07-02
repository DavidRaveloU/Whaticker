// ignore_for_file: constant_identifier_names

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:stikerz/core/services/remote_provider_config.dart';

class TikTokResult {
  final String? videoUrl;
  final String? error;

  const TikTokResult({this.videoUrl, this.error});

  bool get success => videoUrl != null && error == null;
  bool get hasError => error != null;
}

class TikTokService {
  static const String _configUrl =
      'https://gist.githubusercontent.com/DavidRaveloU/b6a9d5a2244fa8cb6c98c18ab45028f4/raw/tiktok_providers.json';

  static final RemoteResolverService _resolver = RemoteResolverService(
    configUrl: _configUrl,
    cacheKey: 'tiktok_providers_cache',
  );

  static const String errExternal = 'err_external_service';
  static const String errTimeout = 'err_timeout';
  static const String errInvalidResponse = 'err_invalid_response';
  static const String errNotVideo = 'err_not_a_video';
  static const String errVideoNotPublic = 'err_video_not_public';
  static const String ERR_INVALID_TIKTOK_LINK = 'err_invalid_tiktok_link';

  static String? extractFirstTikTokUrl(String rawInput) {
    if (rawInput.trim().isEmpty) return null;
    final regex = RegExp(
      r'https?://(?:www\.)?(?:m\.)?(?:vm\.|vt\.)?tiktok\.com/[^\s]+',
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

  static bool isValidTikTokUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return false;
    return uri.host.toLowerCase().contains('tiktok.com');
  }

  static Future<bool> hasInternet() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  static Future<TikTokResult> getVideoUrl(String tiktokUrl) async {
    if (!isValidTikTokUrl(tiktokUrl)) {
      return const TikTokResult(error: ERR_INVALID_TIKTOK_LINK);
    }

    if (!await hasInternet()) {
      return const TikTokResult(error: errExternal);
    }

    final providers = await _resolver.loadProviders();

    if (providers.isEmpty) {
      if (kDebugMode) debugPrint('[TikTokService] ⚠️ No providers loaded');
      return const TikTokResult(error: errExternal);
    }

    for (final provider in providers) {
      final videoUrl = await _resolver.execute(provider, tiktokUrl.trim());
      if (videoUrl != null) {
        if (kDebugMode) {
          debugPrint('[TikTokService] ✅ RESOLVED VIA: ${provider.name}');
        }
        return TikTokResult(videoUrl: videoUrl);
      }
      if (kDebugMode) debugPrint('[TikTokService] ❌ ${provider.name} failed');
    }

    if (kDebugMode) debugPrint('[TikTokService] ⚠️ All providers failed');
    return const TikTokResult(error: errExternal);
  }
}
