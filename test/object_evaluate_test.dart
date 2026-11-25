import 'dart:async';
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

  test(
    'session accepts live stdin, reuses bindings and releases its ID zone on EOF',
    () async {
      final service = await _EvaluationService.start(
        evaluationReply: const {
          'result': {
            'type': '@Instance',
            'kind': 'PlainInstance',
            'id': 'objects/saved',
          },
        },
      );
      final process = await service.session();
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(output.cancel);
      process.stdin.writeln(
        jsonEncode({
          'staticClass': 'Counter',
          'expression': 'newCounter()',
          'as': 'obj',
        }),
      );
      expect(await output.moveNext(), isTrue);
      expect(jsonDecode(output.current)['line'], 1);
      process.stdin.writeln();
      process.stdin.writeln(
        jsonEncode({
          'ref': 'obj',
          'expression': 'compare(peer)',
          'scope': {'peer': 'obj'},
        }),
      );
      expect(await output.moveNext(), isTrue);
      expect(jsonDecode(output.current)['line'], 3);
      await process.stdin.close();
      expect(await output.moveNext(), isFalse);
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
      expect(service.evaluations.last, {
        'isolateId': 'isolates/1',
        'targetId': 'objects/saved',
        'expression': 'compare(peer)',
        'scope': {'peer': 'objects/saved'},
        'idZoneId': 'zones/1',
      });
      expect(service.methods.where((m) => m == 'createIdZone'), hasLength(1));
      expect(service.methods.last, 'deleteIdZone');
      expect(service.methods, isNot(contains('getInstances')));
    },
  );

  test(
    'malformed batch stops at the input line and reports pending recovery',
    () async {
      final service = await _EvaluationService.start(
        evaluationReply: const {
          'result': {
            'type': '@Instance',
            'kind': 'Int',
            'valueAsString': '1',
            'id': 'objects/old',
          },
        },
      );
      final process = await service.session();
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(
        '{"staticClass":"Counter","expression":"count","as":"old","undo":"count = previous"}',
      );
      process.stdin.writeln('bad-json');
      process.stdin.writeln('{"restore":"old"}');
      await process.stdin.close();
      expect(await process.exitCode, 64);
      expect(jsonDecode(await output)['snapshot'], 'old');
      final error = jsonDecode(await errors);
      expect(error['line'], 2);
      expect(error['error']['code'], 'input');
      expect(error['pendingSnapshots'], ['old']);
      expect(service.evaluations, hasLength(1));
      expect(service.methods.last, 'deleteIdZone');
    },
  );

  test(
    'session reports a lost evaluation without dispatching the next step',
    () async {
      final service = await _EvaluationService.start(evaluationReply: null);
      final process = await service.session();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(
        '{"staticClass":"Counter","expression":"increment()"}',
      );
      process.stdin.writeln(
        '{"staticClass":"Counter","expression":"increment()"}',
      );
      await process.stdin.close();
      expect(await process.exitCode, 1);
      final error = jsonDecode(await errors);
      expect(error['line'], 1);
      expect(error['error']['code'], 'disconnected');
      expect(service.evaluations, hasLength(1));
    },
  );

  test(
    'requires the exact loaded URI and supports top-level evaluation',
    () async {
      final service = await _EvaluationService.start();
      Future<ProcessResult> evaluate(String uri) =>
          Process.run(Platform.resolvedExecutable, [
            'run',
            'bin/dart_vm.dart',
            '--uri=http://127.0.0.1:${service.port}/',
            'object',
            'evaluate',
            '--library-uri=$uri',
            '--expression=topLevel()',
          ]);
      final missing = await evaluate('fixture/counter');
      expect(missing.exitCode, 1);
      expect(missing.stderr, contains('found 0'));
      expect(service.evaluations, isEmpty);
      final result = await evaluate('package:fixture/counter.dart');
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(service.evaluations.single['targetId'], 'libraries/1');
      expect(service.methods, isNot(contains('getClassList')));
    },
  );

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
  final methods = <String>[];
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
        service.methods.add(method);
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
              'libraries': [
                {
                  'type': '@Library',
                  'id': 'libraries/1',
                  'uri': 'package:fixture/counter.dart',
                },
              ],
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

  Future<Process> session() async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      '--uri=http://127.0.0.1:$port/',
      'object',
      'session',
    ]);
    addTearDown(process.kill);
    return process;
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
