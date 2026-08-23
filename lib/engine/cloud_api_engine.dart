import 'package:dio/dio.dart';
import 'llm_engine.dart';

class CloudApiEngine implements LlmEngine {
  final Dio client;
  final String apiKey;
  final String endpoint;
  final String model;
  final Map<String, String> extraHeaders;

  CloudApiEngine({
    required this.client,
    required this.apiKey,
    required this.endpoint,
    this.model = '',
    this.extraHeaders = const {},
  });

  @override
  Future<String> generate(String prompt) async {
    final response = await client.post(
      endpoint,
      options: Options(headers: {'Authorization': 'Bearer $apiKey', ...extraHeaders}),
      data: {'prompt': prompt, if (model.isNotEmpty) 'model': model},
    );
    final data = response.data;
    if (data is! Map || data['content'] is! String) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'Unexpected response shape from cloud LLM endpoint',
      );
    }
    return data['content'] as String;
  }
}
