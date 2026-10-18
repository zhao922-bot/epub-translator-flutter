import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';

class AuditWrongWrapperClient extends TranslationApiClient {
  int bodies = 0;
  int calls = 0;
  @override
  Future<Response<dynamic>> postChatCompletions({required Dio dio, required Map<String,dynamic> data, CancelToken? cancelToken}) async {
    calls++;
    final messages=data['messages'] as List;
    final system=(messages.first as Map)['content'] as String;
    final user=(messages.last as Map)['content'] as String;
    Object reply;
    if(system.startsWith('Translate the book title')) {
      reply='译名';
    } else {
      final payload=jsonDecode(user) as Map;
      if(payload['kind']=='initialBookMemory') {
        reply={'bookSummary':'A table.', 'styleGuide':[], 'glossary':[], 'recentChapters':[]};
      } else if(payload['kind']=='chapterMemory') {
        reply={'title':'Table', 'summary':'A table.', 'glossary':[]};
      } else {
        bodies++;
        reply={'blocks':[for(final block in payload['blocks'] as List) {'id':(block as Map)['id'],'html':'<p>译文。</p>'}]};
      }
    }
    return Response(requestOptions:RequestOptions(path:''), data:{'choices':[{'message':{'content':reply is String?reply:jsonEncode(reply)}}]});
  }
}
