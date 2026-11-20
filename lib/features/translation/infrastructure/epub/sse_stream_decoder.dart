import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Accumulates OpenAI-compatible Server-Sent Events into a chat completion.
/// A gateway that ignores `stream: true` may return a regular JSON object.
Future<Map<String, dynamic>> decodeChatCompletionStream({
  required Stream<Uint8List> stream,
  String? contentType,
  CancelToken? cancelToken,
  void Function(String delta)? onContentDelta,
}) async {
  final String normalizedType = (contentType ?? '').toLowerCase();
  bool sawSseFrame = normalizedType.contains('text/event-stream');
  bool isBufferedJson =
      !sawSseFrame && normalizedType.contains('application/json');
  final StringBuffer jsonBuffer = StringBuffer();
  final List<String> eventData = <String>[];
  final StringBuffer contentBuffer = StringBuffer();
  final StringBuffer reasoningBuffer = StringBuffer();
  String? finishReason;
  String role = 'assistant';
  Map<String, dynamic>? usage;
  String? responseId;
  String? responseModel;

  // SSE joins all data fields with newlines before dispatching the event.
  bool dispatchEvent() {
    if (eventData.isEmpty) return false;
    final String payload = eventData.join('\n');
    eventData.clear();
    if (payload.trim().isEmpty) return false;
    if (payload.trim() == '[DONE]') return true;

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error) {
      throw FormatException('Malformed SSE JSON chunk: ${error.message}');
    }
    if (decoded is! Map<Object?, Object?>) return false;

    final Object? errorObj = decoded['error'];
    if (errorObj is Map<Object?, Object?>) {
      final String message =
          errorObj['message']?.toString() ?? errorObj.toString();
      throw FormatException('Upstream SSE error: $message');
    }

    if (decoded['id'] is String) {
      responseId = decoded['id'] as String;
    }
    if (decoded['model'] is String) {
      responseModel = decoded['model'] as String;
    }
    if (decoded['usage'] is Map) {
      usage = Map<String, dynamic>.from(decoded['usage'] as Map);
    }

    final Object? rawChoices = decoded['choices'];
    if (rawChoices is List &&
        rawChoices.isNotEmpty &&
        rawChoices.first is Map) {
      final Map choice = rawChoices.first as Map;
      final Object? reason = choice['finish_reason'];
      if (reason is String && reason.isNotEmpty) {
        finishReason = reason;
      }
      final Object? delta = choice['delta'] ?? choice['message'];
      if (delta is Map) {
        final Object? dRole = delta['role'];
        if (dRole is String && dRole.isNotEmpty) {
          role = dRole;
        }
        final Object? content = delta['content'];
        if (content is String && content.isNotEmpty) {
          contentBuffer.write(content);
          onContentDelta?.call(content);
        }
        final Object? reasoning = delta['reasoning_content'];
        if (reasoning is String && reasoning.isNotEmpty) {
          reasoningBuffer.write(reasoning);
        }
      }
    }
    return false;
  }

  final Stream<String> lines = stream
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  final StreamIterator<String> iterator = StreamIterator<String>(lines);
  // Cancelling the iterator wakes a pending moveNext even when the server
  // has stopped sending bytes. The token may outlive this request.
  StreamIterator<String>? activeIterator = iterator;
  final Future<DioException>? cancellation = cancelToken?.whenCancel;
  if (cancellation != null) {
    cancellation.then((_) => activeIterator?.cancel()).ignore();
  }
  try {
    final DioException? existingCancellation = cancelToken?.cancelError;
    if (existingCancellation != null) throw existingCancellation;
    bool done = false;
    while (!done && await iterator.moveNext()) {
      final DioException? cancellationError = cancelToken?.cancelError;
      if (cancellationError != null) throw cancellationError;
      final String line = iterator.current;
      if (isBufferedJson || (!sawSseFrame && line.trimLeft().startsWith('{'))) {
        isBufferedJson = true;
        jsonBuffer.writeln(line);
      } else if (line.isEmpty) {
        done = dispatchEvent();
      } else if (line.startsWith(':')) {
        sawSseFrame = true;
      } else if (line == 'data' || line.startsWith('data:')) {
        sawSseFrame = true;
        final String data = line == 'data' ? '' : line.substring(5);
        eventData.add(data.startsWith(' ') ? data.substring(1) : data);
      }
    }
    final DioException? cancellationError = cancelToken?.cancelError;
    if (cancellationError != null) throw cancellationError;
    if (isBufferedJson) {
      final Object? decoded = jsonDecode(jsonBuffer.toString());
      if (decoded is Map<Object?, Object?>) {
        return Map<String, dynamic>.from(decoded);
      }
      throw const FormatException(
        'Expected JSON object response from chat API.',
      );
    }
    // Some gateways close after the last data line without a blank separator.
    dispatchEvent();
    return _buildSynthesizedResponse(
      id: responseId,
      model: responseModel,
      role: role,
      content: contentBuffer.toString(),
      reasoningContent: reasoningBuffer.toString(),
      finishReason: finishReason,
      usage: usage,
    );
  } finally {
    activeIterator = null;
    await iterator.cancel();
  }
}

Map<String, dynamic> _buildSynthesizedResponse({
  required String? id,
  required String? model,
  required String role,
  required String content,
  required String reasoningContent,
  required String? finishReason,
  required Map<String, dynamic>? usage,
}) {
  return <String, dynamic>{
    'id': ?id,
    'model': ?model,
    'choices': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'finish_reason': ?finishReason,
        'message': <String, dynamic>{
          'role': role,
          'content': content,
          if (reasoningContent.isNotEmpty)
            'reasoning_content': reasoningContent,
        },
      },
    ],
    'usage': ?usage,
  };
}
