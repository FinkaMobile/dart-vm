import 'dart:async';

import 'package:dart_vm/dart_vm.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  const base = {'class': 'Counter', 'expression': 'value'};
  group('step parsing', () {
    for (final (label, input) in <(String, Object?)>[
      ('non-object', []),
      ('missing target', {'expression': 'x'}),
      ('two targets', {...base, 'staticClass': 'Counter'}),
      ('blank target', {...base, 'class': ' '}),
      ('unknown option', {...base, 'timeOut': 100}),
      ('missing expression', {'ref': 'x'}),
      ('blank expression', {...base, 'expression': '  '}),
      ('invalid name', {...base, 'as': null}),
      ('orphan undo', {...base, 'undo': 'value = previous'}),
      ('malformed fields', {...base, 'fields': 'value'}),
      (
        'invalid path',
        {
          ...base,
          'fields': ['a.'],
        },
      ),
      (
        'non-string field',
        {
          ...base,
          'fields': [1],
        },
      ),
      (
        'non-scalar predicate',
        {
          ...base,
          'where': ['q=[1]'],
        },
      ),
      (
        'where on class',
        {
          'staticClass': 'Counter',
          'expression': 'x',
          'where': ['x=1'],
        },
      ),
      (
        'library filter on ref',
        {'ref': 'x', 'expression': 'x', 'library': 'lib'},
      ),
      ('await type', {...base, 'await': 'yes'}),
      ('timeout needs await', {...base, 'timeoutMs': 1}),
      ('positive timeout', {...base, 'await': true, 'timeoutMs': 0}),
      ('integer timeout', {...base, 'await': true, 'timeoutMs': 3.5}),
      (
        'scope map',
        {
          ...base,
          'scope': ['x'],
        },
      ),
      (
        'invalid alias',
        {
          ...base,
          'scope': {'a-b': 'val'},
        },
      ),
      (
        'empty reference',
        {
          ...base,
          'scope': {'x': ''},
        },
      ),
      (
        'previous collision',
        {
          ...base,
          'scope': {'previous': 'z'},
          'as': 'snap',
          'undo': 'previous',
        },
      ),
      (
        'restore has exclusive target',
        {'restore': 'baseline', 'class': 'Counter'},
      ),
      ('empty restore', {'restore': ''}),
    ]) {
      test(
        'rejects $label',
        () => expect(() => SessionStep.parse(input), throwsFormatException),
      );
    }
    test('types selectors, filters, async deadline and fields at input', () {
      final step =
          SessionStep.parse({
                ...base,
                'library': 'fixture',
                'where': ['id=2'],
                'await': true,
                'timeoutMs': 150,
                'fields': ['items[0]'],
              })
              as EvaluateStep;
      expect(step.context, EvaluationContext.instance);
      expect(step.where.single.value, 2);
      expect(step.options.wait, const Duration(milliseconds: 150));
      expect(step.options.fields, ['items[0]']);
      expect(
        (SessionStep.parse({'restore': 'old', 'await': true}) as RestoreStep)
            .options
            .wait,
        const Duration(seconds: 5),
      );
    });
  });

  late _Client client;
  late ObjectSession session;
  setUp(() {
    client = _Client();
    session = ObjectSession(client);
  });
  Future<Map<String, Object?>> run(Map<String, Object?> input) =>
      session.run(SessionStep.parse(input));
  test(
    'binds scope aliases, pins undo to original target and consumes a successful restore',
    () async {
      await run({
        'staticClass': 'Counter',
        'expression': 'make()',
        'as': 'other',
      });
      await run({
        ...base,
        'as': 'baseline',
        'scope': {'other': 'other'},
        'undo': 'replace(previous, other)',
      });
      await run({
        'ref': 'other',
        'expression': 'set(x)',
        'scope': {'x': 'baseline'},
      });
      final scopedCall = client.calls.last;
      expect(scopedCall.target, 'result1');
      expect(scopedCall.expression, 'set(x)');
      expect(scopedCall.scope, {'x': 'result2'});
      expect(session.pendingSnapshots, ['baseline']);
      await run({'restore': 'baseline'});
      final restore = client.calls.last;
      expect(restore.target, 'instance1');
      expect(restore.expression, 'replace(previous, other)');
      expect(restore.scope, {'other': 'result1', 'previous': 'result2'});
      expect(client.instanceSelections, 1);
      expect(session.pendingSnapshots, isEmpty);
      await expectLater(
        run({'restore': 'baseline'}),
        throwsA(isA<ObjectInspectionException>()),
      );
      await expectLater(
        run({'ref': 'baseline', 'expression': 'this'}),
        throwsA(isA<ObjectInspectionException>()),
      );
      expect(client.calls, hasLength(4));
    },
  );
  test(
    'unknown scopes, duplicate names and unrelated sessions never run the requested expression',
    () async {
      await run({...base, 'as': 'a'});
      await expectLater(
        run({...base, 'as': 'a'}),
        throwsA(isA<ObjectInspectionException>()),
      );
      await expectLater(
        run({
          ...base,
          'scope': {'x': 'missing'},
        }),
        throwsA(isA<ObjectInspectionException>()),
      );
      await expectLater(
        ObjectSession(
          client,
        ).run(SessionStep.parse({'ref': 'a', 'expression': 'this'})),
        throwsA(isA<ObjectInspectionException>()),
      );
      expect(client.calls, hasLength(1));
    },
  );
  test(
    'snapshot stays available if inspection or undo fails; neither is replayed',
    () async {
      await expectLater(
        run({
          ...base,
          'as': 'old',
          'undo': 'undo()',
          'fields': ['absent'],
        }),
        throwsA(
          isA<ObjectInspectionException>().having(
            (e) => e.code,
            'code',
            'resultInspection',
          ),
        ),
      );
      client.fail = true;
      await expectLater(
        run({'restore': 'old'}),
        throwsA(isA<ObjectInspectionException>()),
      );
      expect(session.pendingSnapshots, ['old']);
      expect(client.calls.map((c) => c.expression), ['value', 'undo()']);
    },
  );
  test('failed evaluation never binds a variable', () async {
    client.fail = true;
    await expectLater(
      run({...base, 'as': 'a'}),
      throwsA(isA<ObjectInspectionException>()),
    );
    await expectLater(
      run({'ref': 'a', 'expression': 'this'}),
      throwsA(isA<ObjectInspectionException>()),
    );
    expect(client.calls, hasLength(1));
  });
  test(
    'await polls status only and exposes the resolved result to the next step',
    () async {
      client.statuses.addAll(['0', '1']);
      await run({...base, 'expression': 'next()', 'await': true, 'as': 'v'});
      expect(client.calls, hasLength(2));
      expect(client.calls.first.expression, contains('next()'));
      expect(client.calls.last.target, 'lib:dart:async');
      expect(client.calls.last.scope, {'operation': 'result1'});
      expect(client.polls, 2);
      await run({'ref': 'v', 'expression': 'this'});
      expect(client.calls.last.target, 'answer');
    },
  );
  test('async error includes the message and Dart stack', () async {
    client.statuses.add('2');
    await expectLater(
      run({...base, 'await': true}),
      throwsA(
        isA<ObjectInspectionException>()
            .having((e) => e.code, 'code', 'exception')
            .having((e) => e.message, 'message', contains('bad room'))
            .having((e) => e.dartStack, 'stack', 'stack frame'),
      ),
    );
    expect(client.calls, hasLength(2));
  });
  test('unresponsive VM read times out without another dispatch', () async {
    client.blockRead = Completer<Obj>();
    await expectLater(
      run({...base, 'await': true, 'timeoutMs': 100}),
      throwsA(
        isA<ObjectInspectionException>().having(
          (e) => e.code,
          'code',
          'timeout',
        ),
      ),
    );
    expect(client.calls, hasLength(2));
    expect(client.polls, 1);
  });
}

class _Client implements ObjectInspectorClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  final calls =
      <({String target, String expression, Map<String, String>? scope})>[];
  final statuses = <String>[];
  int instanceSelections = 0;
  int polls = 0;
  bool fail = false;
  Completer<Obj>? blockRead;

  @override
  Future<LibraryRef> requireLibrary(String uri) async =>
      LibraryRef(id: 'lib:$uri', uri: uri);
  @override
  Future<ClassRef> requireClass(String name, {String? library}) async =>
      ClassRef(id: 'class:$name', name: name);
  @override
  Future<ObjRef> uniqueInstance(
    ClassRef classRef,
    List<ObjectWhereClause> where,
  ) async => InstanceRef(id: 'instance${++instanceSelections}');
  @override
  Future<InstanceRef> evaluateOn(
    String targetId,
    String expression, {
    Map<String, String>? scope,
  }) async {
    calls.add((target: targetId, expression: expression, scope: scope));
    if (fail) throw ObjectInspectionException('VM error', code: 'exception');
    return InstanceRef(id: 'result${calls.length}', kind: 'PlainInstance');
  }

  @override
  Future<dynamic> readPath(ObjRef root, String path) async =>
      throw ObjectInspectionException('Field unavailable.');
  @override
  Future<Obj> getObject(String objectId, {int? offset, int? count}) async {
    polls++;
    if (blockRead != null) return blockRead!.future;
    final status = statuses.removeAt(0);
    return Instance(
      id: objectId,
      kind: 'List',
      elements: [
        InstanceRef(id: 'status', kind: 'Int', valueAsString: status),
        InstanceRef(id: 'answer', kind: 'String', valueAsString: 'bad room'),
        InstanceRef(id: 'stack', kind: 'String', valueAsString: 'stack frame'),
      ],
    );
  }

  @override
  Future<Obj> loadValue(dynamic value, {int collectionLimit = 20}) async =>
      Instance(
        id: (value as InstanceRef).id!,
        kind: 'String',
        valueAsString: value.valueAsString,
      );
}
