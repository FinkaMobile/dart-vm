import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'object_inspector_client.dart';

enum EvaluationContext { instance, staticClass, library, ref }

sealed class SessionStep {
  const SessionStep();

  static SessionStep parse(Object? input) {
    if (input is! Map<String, dynamic>) {
      throw const FormatException('Each step must be a JSON object.');
    }
    String? string(String key) {
      if (!input.containsKey(key)) return null;
      final value = input[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be a non-empty string.');
      }
      return value;
    }

    List<String> strings(String key) {
      if (!input.containsKey(key)) return [];
      final value = input[key];
      if (value is! List ||
          !value.every((v) => v is String && v.trim().isNotEmpty)) {
        throw FormatException('$key must be an array of non-empty strings.');
      }
      return value.cast<String>();
    }

    final restoring = input.containsKey('restore');
    final keys = restoring
        ? {'restore', 'await', 'timeoutMs', 'fields'}
        : {
            'class',
            'staticClass',
            'libraryUri',
            'ref',
            'library',
            'where',
            'expression',
            'as',
            'scope',
            'undo',
            'await',
            'timeoutMs',
            'fields',
          };
    for (final key in input.keys) {
      if (!keys.contains(key)) {
        throw FormatException('Unexpected step key: $key.');
      }
    }
    final wait = input.containsKey('await') ? input['await'] : false;
    if (wait is! bool) throw const FormatException('await must be a boolean.');
    final timeout = input.containsKey('timeoutMs') ? input['timeoutMs'] : 5000;
    if (timeout is! int ||
        timeout <= 0 ||
        (input.containsKey('timeoutMs') && !wait)) {
      throw const FormatException(
        'timeoutMs requires await=true and a positive integer.',
      );
    }
    final fields = strings('fields');
    for (final path in fields) {
      parseObjectPath(path);
    }
    final options = (
      wait: wait ? Duration(milliseconds: timeout) : null,
      fields: fields,
    );
    if (restoring) return RestoreStep(string('restore')!, options);

    final selectors = {
      'class': EvaluationContext.instance,
      'staticClass': EvaluationContext.staticClass,
      'libraryUri': EvaluationContext.library,
      'ref': EvaluationContext.ref,
    };
    final selected = selectors.keys.where(input.containsKey).toList();
    if (selected.length != 1) {
      throw const FormatException(
        'Choose exactly one of class, staticClass, libraryUri or ref.',
      );
    }
    final context = selectors[selected.single]!;
    final target = string(selected.single)!;
    final library = string('library');
    if (library != null &&
        context != EvaluationContext.instance &&
        context != EvaluationContext.staticClass) {
      throw const FormatException('library only filters class or staticClass.');
    }
    if (input.containsKey('where') && context != EvaluationContext.instance) {
      throw const FormatException('where requires an instance class.');
    }
    final List<ObjectWhereClause> where;
    try {
      where = strings('where').map(parseObjectWhereClause).toList();
    } on FormatException catch (error) {
      throw FormatException('Invalid --where: ${error.message}');
    }
    final expression = string('expression');
    if (expression == null) {
      throw const FormatException('expression is required.');
    }
    final save = string('as');
    final undo = string('undo');
    if (undo != null && save == null) {
      throw const FormatException('undo requires as.');
    }

    final scope = <String, String>{};
    if (input.containsKey('scope')) {
      final bindings = input['scope'];
      if (bindings is! Map<String, dynamic>) {
        throw const FormatException(
          'scope must map Dart identifiers to saved names.',
        );
      }
      for (final entry in bindings.entries) {
        if (!RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(entry.key) ||
            entry.value is! String ||
            (entry.value as String).trim().isEmpty) {
          throw const FormatException(
            'scope must map Dart identifiers to saved names.',
          );
        }
        scope[entry.key] = entry.value as String;
      }
    }
    if (undo != null && scope.containsKey('previous')) {
      throw const FormatException('undo reserves the scope name previous.');
    }
    return EvaluateStep(
      context: context,
      target: target,
      expression: expression,
      library: library,
      where: where,
      scope: scope,
      save: save,
      undo: undo,
      options: options,
    );
  }
}

typedef EvaluationOptions = ({Duration? wait, List<String> fields});

final class EvaluateStep extends SessionStep {
  const EvaluateStep({
    required this.context,
    required this.target,
    required this.expression,
    required this.library,
    required this.where,
    required this.scope,
    required this.save,
    required this.undo,
    required this.options,
  });
  final EvaluationContext context;
  final String target;
  final String expression;
  final String? library;
  final List<ObjectWhereClause> where;
  final Map<String, String> scope;
  final String? save;
  final String? undo;
  final EvaluationOptions options;
}

final class RestoreStep extends SessionStep {
  const RestoreStep(this.name, this.options);
  final String name;
  final EvaluationOptions options;
}

class ObjectSession {
  ObjectSession(this.client);

  final ObjectInspectorClient client;
  final _bindings = <String, String>{};
  final _snapshots =
      <String, ({String target, String undo, Map<String, String> scope})>{};
  Iterable<String> get pendingSnapshots => _snapshots.keys;

  Future<Map<String, Object?>> run(SessionStep step) async {
    final output = <String, Object?>{};
    late final InstanceRef result;
    late final EvaluationOptions options;
    switch (step) {
      case EvaluateStep():
        final save = step.save;
        if (save != null && _bindings.containsKey(save)) {
          throw ObjectInspectionException(
            'Name "$save" is already bound in this session.',
          );
        }
        final scope = {
          for (final e in step.scope.entries) e.key: _binding(e.value),
        };
        final String targetId;
        switch (step.context) {
          case EvaluationContext.instance:
          case EvaluationContext.staticClass:
            final cls = await client.requireClass(
              step.target,
              library: step.library,
            );
            targetId = step.context == EvaluationContext.instance
                ? (await client.uniqueInstance(cls, step.where)).id!
                : cls.id!;
            output['class'] = describeClass(cls);
            if (step.context == EvaluationContext.staticClass) {
              output['context'] = 'staticClass';
            }
            if (step.where.isNotEmpty) {
              output['where'] = step.where.map((w) => w.toJson()).toList();
            }
          case EvaluationContext.library:
            targetId = (await client.requireLibrary(step.target)).id!;
            output['libraryUri'] = step.target;
          case EvaluationContext.ref:
            targetId = _binding(step.target);
            output['ref'] = step.target;
        }
        options = step.options;
        result = await _evaluate(
          targetId,
          step.expression,
          scope,
          options.wait,
        );
        if (save != null) {
          final id = result.id;
          if (id == null) {
            throw ObjectInspectionException(
              'The VM returned no object ID for "$save".',
            );
          }
          _bindings[save] = id;
          output['as'] = save;
          if (step.undo case final undo?) {
            _snapshots[save] = (
              target: targetId,
              undo: undo,
              scope: {...scope, 'previous': id},
            );
            output['snapshot'] = save;
          }
        }
      case RestoreStep():
        final snapshot = _snapshots[step.name];
        if (snapshot == null) {
          throw ObjectInspectionException(
            'No pending snapshot named "${step.name}".',
          );
        }
        options = step.options;
        result = await _evaluate(
          snapshot.target,
          snapshot.undo,
          snapshot.scope,
          options.wait,
        );
        _snapshots.remove(step.name);
        _bindings.remove(step.name);
        output['restored'] = step.name;
    }
    output['result'] = describeReference(result);
    if (options.fields.isNotEmpty) {
      try {
        output['fields'] = {
          for (final path in options.fields)
            path: describeReference(await client.readPath(result, path)),
        };
      } on ObjectInspectionException catch (error) {
        throw ObjectInspectionException(
          'Expression completed. Result inspection failed: ${error.message}',
          code: 'resultInspection',
          next: error.next,
        );
      }
    }
    return output;
  }

  String _binding(String name) =>
      _bindings[name] ??
      (throw ObjectInspectionException('Unknown session name "$name".'));

  Future<InstanceRef> _evaluate(
    String target,
    String expression,
    Map<String, String> scope,
    Duration? wait,
  ) async {
    if (wait == null) {
      return client.evaluateOn(
        target,
        expression,
        scope: scope.isEmpty ? null : scope,
      );
    }
    final timer = Stopwatch()..start();
    Duration remaining() {
      final left = wait - timer.elapsed;
      if (left <= Duration.zero) {
        throw TimeoutException('Evaluation timed out.');
      }
      return left;
    }

    try {
      // Compile the caller's expression in its original lexical scope. Run
      // the observer in dart:async so its names cannot shadow that expression.
      final lib = await client
          .requireLibrary('dart:async')
          .timeout(remaining());
      final thunk = await client
          .evaluateOn(
            target,
            '() async => (\n$expression\n)',
            scope: scope.isEmpty ? null : scope,
          )
          .timeout(remaining());
      final box = await client
          .evaluateOn(
            lib.id!,
            r'''
(() {
  final box = <dynamic>[0, null, null];
  Future<dynamic>(() => operation()).then<void>(
    (value) { box[1] = value; box[0] = 1; },
    onError: (Object error, StackTrace stack) {
      box[0] = 2;
      box[1] = error.toString();
      box[2] = stack.toString();
    },
  );
  return box;
})()
''',
            scope: {'operation': thunk.id!},
          )
          .timeout(remaining());
      while (true) {
        final object =
            await client.getObject(box.id!, count: 3).timeout(remaining())
                as Instance;
        final values = object.elements!;
        final status = (values[0] as InstanceRef).valueAsString;
        if (status == '1') {
          // vm_service decodes null list elements to host null. Keep the
          // original wire reference so a saved null can be passed in scope.
          return values[1] as InstanceRef? ??
              InstanceRef.parse(object.json!['elements'][1])!;
        }
        if (status == '2') {
          final error =
              await client.loadValue(values[1]).timeout(remaining())
                  as Instance;
          final stack =
              await client.loadValue(values[2]).timeout(remaining())
                  as Instance;
          throw ObjectInspectionException(
            'Expression threw: ${error.valueAsString}.',
            code: 'exception',
            dartStack: stack.valueAsString,
          );
        }
        final left = remaining();
        const interval = Duration(milliseconds: 25);
        await Future<void>.delayed(left < interval ? left : interval);
      }
    } on TimeoutException {
      throw ObjectInspectionException(
        'Timed out after ${wait.inMilliseconds} ms. The target operation may still complete.',
        code: 'timeout',
      );
    }
  }
}
