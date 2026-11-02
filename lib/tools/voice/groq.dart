// Groq cloud: Whisper large-v3 speech-to-text (much more accurate than the
// small on-device model) and LLM translation. OpenAI-compatible API.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class GroqException implements Exception {
  GroqException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GroqClient {
  GroqClient(this.apiKey, {http.Client? client}) : _http = client ?? http.Client();

  final String apiKey;
  final http.Client _http;

  static const base = 'https://api.groq.com/openai/v1';
  static const sttModel = 'whisper-large-v3';

  /// Preferred translation models, best first. The list Groq actually serves is
  /// checked at runtime because Groq retires models regularly.
  static const preferredChatModels = [
    'openai/gpt-oss-120b',
    'llama-3.3-70b-versatile',
    'moonshotai/kimi-k2-instruct',
    'qwen/qwen3-32b',
    'openai/gpt-oss-20b',
    'llama-3.1-8b-instant',
  ];

  static String? _cachedChatModel;

  Map<String, String> get _auth => {'Authorization': 'Bearer $apiKey'};

  Future<bool> checkKey() async {
    try {
      await _models();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _models() async {
    final r = await _http.get(Uri.parse('$base/models'), headers: _auth).timeout(const Duration(seconds: 20));
    _check(r.statusCode, r.body);
    final data = (jsonDecode(r.body) as Map)['data'] as List;
    return [for (final m in data) (m as Map)['id'] as String];
  }

  Future<String> transcribe(File audio, String language) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/audio/transcriptions'))
      ..headers.addAll(_auth)
      ..fields['model'] = sttModel
      ..fields['language'] = language
      ..fields['temperature'] = '0'
      ..fields['response_format'] = 'json';
    // WhatsApp's .opus files are Ogg/Opus; name them .ogg so the API recognises the type.
    var name = p.basename(audio.path);
    if (name.toLowerCase().endsWith('.opus')) name = '${p.basenameWithoutExtension(name)}.ogg';
    req.files.add(await http.MultipartFile.fromPath('file', audio.path, filename: name));
    final streamed = await _http.send(req).timeout(const Duration(minutes: 3));
    final body = await streamed.stream.bytesToString();
    _check(streamed.statusCode, body);
    return ((jsonDecode(body) as Map)['text'] as String? ?? '').trim();
  }

  Future<String> _chatModel() async {
    if (_cachedChatModel != null) return _cachedChatModel!;
    final available = (await _models()).toSet();
    final pick = preferredChatModels.firstWhere(
      available.contains,
      orElse: () {
        final fallback = available.where(
          (m) => !m.contains('whisper') && !m.contains('guard') && !m.contains('tts') && !m.contains('orpheus'),
        );
        if (fallback.isEmpty) throw GroqException('No translation model available on Groq');
        return fallback.first;
      },
    );
    return _cachedChatModel = pick;
  }

  Future<String> translate(String text, String fromName, String toName) async {
    final model = await _chatModel();
    final r = await _http
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'temperature': 0.2,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You translate WhatsApp voice-note transcripts from $fromName to $toName. '
                    'Keep the meaning, tone and informal style. Fix obvious speech-recognition slips only '
                    'when the intended word is clear. Reply with the translation only - no notes, no quotes.',
              },
              {'role': 'user', 'content': text},
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    _check(r.statusCode, r.body);
    final choices = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['choices'] as List;
    var out = (((choices.first as Map)['message'] as Map)['content'] as String? ?? '').trim();
    // Some reasoning models wrap their thinking in <think> tags.
    out = out.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    return out;
  }

  static void _check(int status, String body) {
    if (status >= 200 && status < 300) return;
    String msg = 'Groq error $status';
    try {
      final e = (jsonDecode(body) as Map)['error'];
      if (e is Map && e['message'] != null) msg = 'Groq: ${e['message']}';
    } catch (_) {}
    if (status == 401) msg = 'Groq rejected the API key (check it in Settings)';
    if (status == 429) msg = 'Groq rate limit reached - wait a minute and try again';
    throw GroqException(msg);
  }
}
