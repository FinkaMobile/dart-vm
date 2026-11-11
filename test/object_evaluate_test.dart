import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('evaluates once on the uniquely filtered instance', () async {
    final service = await _EvaluationService.start(candidates: [1, 2, 3]);
    const expression = 'count = [2, 7].last';
    final result = await service.evaluate(
      expression,
      selectors: [
        '--isolate=main',
        '--library=package:fixture/',
        '--where=id=3',
      ],
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stderr, isEmpty);
    expect(jsonDecode(result.stdout as String), {
      'isolate': {'id': 'isolates/1', 'name': 'main'},
      'class': {
        'id': 'classes/1',
        'name': 'Counter',
        'library': 'package:fixture/counter.dart',
      },
      'where': [
        {'path': 'id', 'value': 3},
      ],
      'result': {'kind': 'Int', 'value': 7},
    });
    expect(service.evaluations, [
      {
        'isolateId': 'isolates/1',
        'targetId': 'objects/3/1',
        'expression': expression,
        'idZoneId': 'zones/1',
      },
    ]);
  });

  for (final (candidates, totalCount, message) in [
    (<int>[], 0, 'No live instance'),
    ([1, 2], 2, 'Multiple live instances'),
    ([1], 3, 'Could not confirm a unique live instance'),
  ]) {
    test('skips evaluation when reporting "$message"', () async {
      final service = await _EvaluationService.start(
        candidates: candidates,
        totalCount: totalCount,
      );
      final result = await service.evaluate('count++');

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains(message));
      expect(service.evaluations, isEmpty);
    });
  }

  for (final (reply, message) in <(Map<String, Object?>?, String)>[
    (
      {
        'error': {'code': 113, 'message': 'Invalid Dart syntax'},
      },
      'Expression compilation failed',
    ),
    (
      {
        'error': {'code': 100, 'message': 'Feature is disabled'},
      },
      'Expression evaluation is unavailable',
    ),
    (
      {
        'result': {
          'type': '@Error',
          'id': 'objects/2/1',
          'kind': 'UnhandledException',
          'message': 'StateError: fixture failure',
        },
      },
      'Expression threw: StateError: fixture failure',
    ),
    (
      {
        'result': {
          'type': 'Sentinel',
          'kind': 'Expired',
          'valueAsString': '<expired>',
        },
      },
      'Evaluation target is unavailable: Expired',
    ),
    (null, 'The execution outcome is unknown'),
  ]) {
    test('reports "$message" after one evaluation request', () async {
      final service = await _EvaluationService.start(evaluationReply: reply);
      final result = await service.evaluate('count++');

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains(message));
      expect(service.evaluations, hasLength(1));
    });
  }
}

class _EvaluationService {
  _EvaluationService(this.port);

  final int port;
  final evaluations = <Map<String, dynamic>>[];

  static Future<_EvaluationService> start({
    List<int> candidates = const [1],
    int? totalCount,
    Map<String, Object?>? evaluationReply = const {
      'result': {'type': '@Instance', 'kind': 'Int', 'valueAsString': '7'},
    },
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final service = _EvaluationService(server.port);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final message in socket) {
        final call = jsonDecode(message as String) as Map<String, dynamic>;
        final params = call['params'] as Map<String, dynamic>;
        final method = call['method'] as String;
        Map<String, Object?>? reply;
        if (method == 'evaluate') {
          service.evaluations.add(params);
          reply = evaluationReply;
          if (reply == null) {
            await socket.close();
            break;
          }
        } else {
          final result = switch (method) {
            'getVM' => {
              'type': 'VM',
              'isolates': [
                {'type': '@Isolate', 'id': 'isolates/1', 'name': 'main'},
              ],
            },
            'getIsolate' => {
              'type': 'Isolate',
              'runnable': true,
              'name': 'main',
            },
            'createIdZone' => {'type': 'IdZone', 'id': 'zones/1'},
            'getClassList' => {
              'type': 'ClassList',
              'classes': [
                {
                  'type': '@Class',
                  'id': 'classes/1',
                  'name': 'Counter',
                  'library': {
                    'type': '@Library',
                    'uri': 'package:fixture/counter.dart',
                  },
                },
              ],
            },
            'getInstances' => {
              'type': 'InstanceSet',
              'totalCount': totalCount ?? candidates.length,
              'instances': [
                for (final id in candidates.take(params['limit'] as int))
                  {
                    'type': '@Instance',
                    'id': 'objects/$id/1',
                    'kind': 'PlainInstance',
                  },
              ],
            },
            'getObject' => {
              'type': 'Instance',
              'kind': 'PlainInstance',
              'fields': [
                {
                  'name': 'id',
                  'value': {
                    'type': '@Instance',
                    'kind': 'Int',
                    'valueAsString': (params['objectId'] as String).split(
                      '/',
                    )[1],
                  },
                },
              ],
            },
            'deleteIdZone' => {'type': 'Success'},
            _ => throw StateError('Unexpected VM Service method: $method'),
          };
          reply = {'result': result};
        }
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': call['id'], ...reply}));
      }
    });
    return service;
  }

  Future<ProcessResult> evaluate(
    String expression, {
    List<String> selectors = const [],
  }) => Process.run(Platform.resolvedExecutable, [
    'run',
    'bin/dart_vm.dart',
    '--uri=http://127.0.0.1:$port/',
    'object',
    'evaluate',
    '--class=Counter',
    ...selectors,
    '--expression=$expression',
  ]);
}
