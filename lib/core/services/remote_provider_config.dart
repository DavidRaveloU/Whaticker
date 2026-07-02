// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class RemoteTokenStep {
  final String method;
  final String url;
  final Map<String, String> headers;
  final List<String> extractionPatterns;

  RemoteTokenStep({
    required this.method,
    required this.url,
    required this.headers,
    required this.extractionPatterns,
  });

  factory RemoteTokenStep.fromJson(Map<String, dynamic> json) {
    return RemoteTokenStep(
      method: (json['method'] as String? ?? 'GET').toUpperCase(),
      url: json['url'] as String,
      headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
      extractionPatterns: List<String>.from(
        json['extractionPatterns'] as List? ?? [],
      ),
    );
  }
}

class RemoteRejectCheck {
  final String path;
  final bool nonEmptyList;

  RemoteRejectCheck({required this.path, required this.nonEmptyList});

  factory RemoteRejectCheck.fromJson(Map<String, dynamic> json) {
    return RemoteRejectCheck(
      path: json['path'] as String,
      nonEmptyList: json['nonEmptyList'] as bool? ?? false,
    );
  }
}

class RemoteProvider {
  final String name;
  final bool enabled;
  final String method;
  final String url;
  final String bodyType; // 'json' | 'form'
  final Map<String, String> headers;
  final Map<String, dynamic> bodyTemplate;
  final String responseType; // 'json' | 'html'
  final Map<String, dynamic>? successCheck;
  final List<RemoteRejectCheck> rejectChecks;
  final String? videoUrlPath;
  final List<String> videoUrlPathCandidates;
  final List<String> extractionPatterns;
  final RemoteTokenStep? tokenFetch;
  final bool requireVideoLike;

  RemoteProvider({
    required this.name,
    required this.enabled,
    required this.method,
    required this.url,
    required this.bodyType,
    required this.headers,
    required this.bodyTemplate,
    required this.responseType,
    this.successCheck,
    this.rejectChecks = const [],
    this.videoUrlPath,
    this.videoUrlPathCandidates = const [],
    this.extractionPatterns = const [],
    this.tokenFetch,
    this.requireVideoLike = false,
  });

  factory RemoteProvider.fromJson(Map<String, dynamic> json) {
    return RemoteProvider(
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
      method: (json['method'] as String? ?? 'POST').toUpperCase(),
      url: json['url'] as String,
      bodyType: json['bodyType'] as String? ?? 'json',
      headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
      bodyTemplate: Map<String, dynamic>.from(
        json['bodyTemplate'] as Map? ?? {},
      ),
      responseType: json['responseType'] as String? ?? 'json',
      successCheck: json['successCheck'] != null
          ? Map<String, dynamic>.from(json['successCheck'] as Map)
          : null,
      rejectChecks: (json['rejectChecks'] as List? ?? [])
          .map((r) => RemoteRejectCheck.fromJson(r as Map<String, dynamic>))
          .toList(),
      videoUrlPath: json['videoUrlPath'] as String?,
      videoUrlPathCandidates: List<String>.from(
        json['videoUrlPathCandidates'] as List? ?? [],
      ),
      extractionPatterns: List<String>.from(
        json['extractionPatterns'] as List? ?? [],
      ),
      tokenFetch: json['tokenFetch'] != null
          ? RemoteTokenStep.fromJson(json['tokenFetch'] as Map<String, dynamic>)
          : null,
      requireVideoLike: json['requireVideoLike'] as bool? ?? false,
    );
  }
}

/// Motor genérico: descarga config remota (con cache offline) y ejecuta
/// cualquier proveedor descrito en JSON, sin necesitar código Dart nuevo.
class RemoteResolverService {
  final String configUrl;
  final String cacheKey;

  RemoteResolverService({required this.configUrl, required this.cacheKey});

  Future<List<RemoteProvider>> loadProviders() async {
    final prefs = await SharedPreferences.getInstance();
    String? rawJson;

    try {
      final response = await http
          .get(Uri.parse(configUrl))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        rawJson = response.body;
        await prefs.setString(cacheKey, rawJson);
        if (kDebugMode)
          debugPrint('[RemoteResolver:$cacheKey] ✅ Fetched fresh config');
      } else {
        if (kDebugMode) {
          debugPrint(
            '[RemoteResolver:$cacheKey] ⚠️ Fetch failed (${response.statusCode}), using cache',
          );
        }
        rawJson = prefs.getString(cacheKey);
      }
    } catch (e) {
      if (kDebugMode)
        debugPrint(
          '[RemoteResolver:$cacheKey] ⚠️ Fetch error: $e, using cache',
        );
      rawJson = prefs.getString(cacheKey);
    }

    if (rawJson == null) return [];

    try {
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      final providersJson = decoded['providers'] as List;
      return providersJson
          .map((p) => RemoteProvider.fromJson(p as Map<String, dynamic>))
          .where((p) => p.enabled)
          .toList();
    } catch (e) {
      if (kDebugMode)
        debugPrint('[RemoteResolver:$cacheKey] ❌ Parse error: $e');
      return [];
    }
  }

  Future<String?> execute(RemoteProvider provider, String targetUrl) async {
    try {
      String? token;

      // Paso opcional: obtener token antes de la petición principal (ej. ssstik).
      if (provider.tokenFetch != null) {
        token = await _runTokenFetch(provider.tokenFetch!);
        if (token == null) {
          if (kDebugMode) {
            debugPrint('[RemoteResolver] ${provider.name}: token fetch failed');
          }
          return null;
        }
      }

      final body = _fillTemplateMap(provider.bodyTemplate, targetUrl, token);

      http.Response response;
      if (provider.method == 'GET') {
        final uri = Uri.parse(provider.url).replace(
          queryParameters: body.map((k, v) => MapEntry(k, v.toString())),
        );
        response = await http
            .get(uri, headers: provider.headers)
            .timeout(const Duration(seconds: 25));
      } else if (provider.bodyType == 'form') {
        response = await http
            .post(
              Uri.parse(provider.url),
              headers: provider.headers,
              body: body.map((k, v) => MapEntry(k, v.toString())),
            )
            .timeout(const Duration(seconds: 25));
      } else {
        response = await http
            .post(
              Uri.parse(provider.url),
              headers: provider.headers,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 25));
      }

      if (kDebugMode) {
        debugPrint(
          '[RemoteResolver] ${provider.name} status: ${response.statusCode}',
        );
      }

      if (response.statusCode != 200) return null;

      if (provider.responseType == 'html') {
        return _extractWithPatterns(response.body, provider.extractionPatterns);
      }

      // responseType == 'json'
      final json = jsonDecode(response.body);

      if (provider.successCheck != null) {
        final checkValue = _navigatePath(
          json,
          provider.successCheck!['path'] as String,
        );
        if (checkValue.toString() !=
            provider.successCheck!['equals'].toString()) {
          return null;
        }
      }

      for (final reject in provider.rejectChecks) {
        final value = _navigatePath(json, reject.path);
        if (reject.nonEmptyList && value is List && value.isNotEmpty) {
          return null;
        }
      }

      if (provider.videoUrlPath != null) {
        return _navigatePath(json, provider.videoUrlPath!)?.toString();
      }

      for (final path in provider.videoUrlPathCandidates) {
        final candidate = _navigatePath(json, path)?.toString();
        if (candidate == null || candidate.isEmpty) continue;
        if (!provider.requireVideoLike || _looksLikeVideo(candidate)) {
          return candidate;
        }
      }

      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[RemoteResolver] ${provider.name} error: $e');
      return null;
    }
  }

  Future<String?> _runTokenFetch(RemoteTokenStep step) async {
    try {
      final response =
          await (step.method == 'POST'
                  ? http.post(Uri.parse(step.url), headers: step.headers)
                  : http.get(Uri.parse(step.url), headers: step.headers))
              .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;
      return _extractWithPatterns(response.body, step.extractionPatterns);
    } catch (e) {
      if (kDebugMode) debugPrint('[RemoteResolver] tokenFetch error: $e');
      return null;
    }
  }

  Map<String, dynamic> _fillTemplateMap(
    Map<String, dynamic> template,
    String targetUrl,
    String? token,
  ) {
    final result = <String, dynamic>{};
    template.forEach((key, value) {
      if (value is String) {
        result[key] = value
            .replaceAll('{{url}}', targetUrl)
            .replaceAll('{{instagramUrl}}', targetUrl) // compat con gist actual
            .replaceAll('{{token}}', token ?? '');
      } else {
        result[key] = value;
      }
    });
    return result;
  }

  String? _extractWithPatterns(String text, List<String> patterns) {
    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(text);
      final group = match?.group(1);
      if (group != null && group.isNotEmpty) return group;
    }
    return null;
  }

  bool _looksLikeVideo(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final mimeType = uri.queryParameters['mime_type']?.toLowerCase();
    if (mimeType != null && mimeType.contains('video')) return true;
    final path = uri.path.toLowerCase();
    return path.contains('/video/') || path.endsWith('.mp4');
  }

  dynamic _navigatePath(dynamic json, String path) {
    dynamic current = json;
    for (final segment in path.split('.')) {
      if (current == null) return null;
      final index = int.tryParse(segment);
      if (index != null && current is List) {
        if (index >= current.length) return null;
        current = current[index];
      } else if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }
}
