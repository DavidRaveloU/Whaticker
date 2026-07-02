// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class InstagramResult {
  final String? videoUrl;
  final String? error;

  const InstagramResult({this.videoUrl, this.error});

  bool get success => videoUrl != null && error == null;
  bool get hasError => error != null;
}

class InstagramService {
  static const String _downReelsEndpoint =
      'https://downreels.com/api/fetch.php';
  static const String _magicSlidesEndpoint =
      'https://www.magicslides.app/api/tools/instagram-downloader';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';

  // Error tokens returned to the UI and mapped to localized messages.
  static const String errExternal = 'err_external_service';
  static const String errTimeout = 'err_timeout';
  static const String errInvalidResponse = 'err_invalid_response';
  static const String errNotVideo = 'err_not_a_video';
  static const String errVideoNotPublic = 'err_video_not_public';

  // ---------------------------------------------------------------------
  // Public helpers
  // ---------------------------------------------------------------------

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

  static String? _extractShortcode(String instagramUrl) {
    final uri = Uri.tryParse(instagramUrl);
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final typeIndex = segments.indexWhere(
      (s) => s == 'reel' || s == 'p' || s == 'tv',
    );
    if (typeIndex == -1 || typeIndex + 1 >= segments.length) return null;
    return segments[typeIndex + 1];
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

  // ---------------------------------------------------------------------
  // Orquestador principal: prueba los métodos en cascada
  // ---------------------------------------------------------------------

  static Future<InstagramResult> getVideoUrl(String instagramUrl) async {
    if (!isValidInstagramUrl(instagramUrl)) {
      return const InstagramResult(error: errInvalidResponse);
    }

    if (!await hasInternet()) {
      return const InstagramResult(error: errExternal);
    }

    final shortcode = _extractShortcode(instagramUrl);
    if (shortcode == null) {
      return const InstagramResult(error: errInvalidResponse);
    }

    final methods = <String, Future<String?> Function()>{
      'DOWNREELS': () => _tryDownReels(instagramUrl),
      'MAGICSLIDES': () => _tryMagicSlides(instagramUrl),
    };

    for (final entry in methods.entries) {
      final videoUrl = await entry.value();
      if (videoUrl != null) {
        if (kDebugMode) {
          debugPrint('[InstagramService] ✅ RESOLVED VIA: ${entry.key}');
        }
        return InstagramResult(videoUrl: videoUrl);
      }
      if (kDebugMode) {
        debugPrint('[InstagramService] ❌ ${entry.key} failed');
      }
    }

    if (kDebugMode) debugPrint('[InstagramService] ⚠️ All methods failed');
    return const InstagramResult(error: errExternal);
  }

  // ---------------------------------------------------------------------
  // Método 1: downreels.com
  // ---------------------------------------------------------------------

  static Future<String?> _tryDownReels(String instagramUrl) async {
    try {
      final response = await http
          .post(
            Uri.parse(_downReelsEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': _userAgent,
              'Referer': 'https://downreels.com/',
              'Origin': 'https://downreels.com',
            },
            body: jsonEncode({'url': instagramUrl}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body);
      if (json['status'] != 'ok') return null;

      final videos = json['videos'] as List?;
      if (videos == null || videos.isEmpty) return null;

      return videos[0]['url'] as String?;
    } catch (e) {
      if (kDebugMode) debugPrint('[InstagramService] _tryDownReels error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Método 2: magicslides.app
  // ---------------------------------------------------------------------

  static Future<String?> _tryMagicSlides(String instagramUrl) async {
    try {
      final response = await http
          .post(
            Uri.parse(_magicSlidesEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': _userAgent,
              'Referer': 'https://www.magicslides.app/',
              'Origin': 'https://www.magicslides.app',
            },
            body: jsonEncode({'url': instagramUrl}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body);
      return json['videoUrl'] as String?;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[InstagramService] _tryMagicSlides error: $e');
      }
      return null;
    }
  }
}
