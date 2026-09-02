import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'vm_service_uri.dart';

class ObjectInspectionException implements Exception {
  ObjectInspectionException(this.message, {this.next});

  final String message;
  final String? next;

  @override
  String toString() => next == null ? message : '$message\nNext: $next';
}

sealed class ObjectPathSegment {
  const ObjectPathSegment();
}

class ObjectFieldPathSegment extends ObjectPathSegment {
  const ObjectFieldPathSegment(this.name);

  final String name;

  @override
  String toString() => name;
}

class ObjectBracketPathSegment extends ObjectPathSegment {
  const ObjectBracketPathSegment(this.key);

  final Object? key;

  @override
  String toString() => '[${jsonEncode(key)}]';
}

List<ObjectPathSegment> parseObjectPath(String path) {
  if (path.isEmpty) {
    throw const FormatException('Object path must not be empty.');
  }

  final segments = <ObjectPathSegment>[];
  var offset = 0;
  var expectsField = true;
  while (offset < path.length) {
    final character = path[offset];
    if (character == '.') {
      if (expectsField) {
        throw FormatException('Unexpected "." at character ${offset + 1}.');
      }
      expectsField = true;
      offset++;
      continue;
    }

    if (character == '[') {
      final close = _findClosingBracket(path, offset);
      final rawKey = path.substring(offset + 1, close).trim();
      if (rawKey.isEmpty) {
        throw FormatException('Empty brackets at character ${offset + 1}.');
      }
      segments.add(ObjectBracketPathSegment(_parseBracketKey(rawKey)));
      offset = close + 1;
      expectsField = false;
      continue;
    }

    if (!expectsField) {
      throw FormatException('Expected "." or "[" at character ${offset + 1}.');
    }
    final start = offset;
    while (offset < path.length && path[offset] != '.' && path[offset] != '[') {
      offset++;
    }
    final field = path.substring(start, offset);
    if (field.isEmpty) {
      throw FormatException('Expected a field at character ${start + 1}.');
    }
    segments.add(ObjectFieldPathSegment(field));
    expectsField = false;
  }

  if (expectsField) {
    throw FormatException('Object path must not end with ".".');
  }
  return segments;
}

int _findClosingBracket(String path, int open) {
  var quoted = false;
  var escaped = false;
  for (var index = open + 1; index < path.length; index++) {
    final character = path[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quoted && character == '\\') {
      escaped = true;
      continue;
    }
    if (character == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && character == ']') {
      return index;
    }
  }
  throw FormatException('Missing "]" for bracket at character ${open + 1}.');
}

Object? _parseBracketKey(String source) {
  late final dynamic value;
  try {
    value = jsonDecode(source);
  } on FormatException {
    _throwInvalidBracketKey(source);
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  _throwInvalidBracketKey(source);
}

Never _throwInvalidBracketKey(String source) {
  throw FormatException(
    'Invalid bracket key "$source". Use a non-negative list index or a JSON scalar Map key such as [0], ["name"], [true], or [null].',
  );
}

class ObjectInspectorClient {
  ObjectInspectorClient._(this._service, this.isolateId, this.isolateName);

  final VmService _service;
  final String isolateId;
  final String isolateName;

  static Future<ObjectInspectorClient> connect(
    String uri, {
    String? isolate,
  }) async {
    final service = await vmServiceConnectUri(normalizeVmServiceUri(uri));
    try {
      final vm = await service.getVM();
      final selected = _selectIsolate(
        vm.isolates ?? const <IsolateRef>[],
        isolate,
      );
      final id = selected.id!;
      final detail = await service.getIsolate(id);
      if (detail.runnable != true) {
        throw ObjectInspectionException(
          'Isolate ${detail.name ?? id} is not runnable.',
          next:
              'Resume the App or select another isolate with --isolate <name-or-id>.',
        );
      }
      return ObjectInspectorClient._(
        service,
        id,
        detail.name ?? selected.name ?? id,
      );
    } catch (_) {
      await service.dispose();
      rethrow;
    }
  }

  Future<List<ClassRef>> findClasses({
    required String name,
    String? library,
    bool exact = false,
  }) async {
    late final List<ClassRef> classes;
    try {
      classes = (await _service.getClassList(isolateId)).classes ?? [];
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'The VM could not list loaded classes: ${_rpcMessage(error)}.',
        next:
            'Confirm the App is running in Debug or Profile mode and reconnect with dart-vm service list.',
      );
    }
    final matches = classes.where((candidate) {
      final candidateName = candidate.name ?? '';
      final nameMatches = exact
          ? candidateName == name
          : candidateName.contains(name);
      final libraryMatches =
          library == null || (candidate.library?.uri ?? '').contains(library);
      return nameMatches && libraryMatches;
    }).toList();
    matches.sort((left, right) {
      final nameOrder = (left.name ?? '').compareTo(right.name ?? '');
      if (nameOrder != 0) return nameOrder;
      return (left.library?.uri ?? '').compareTo(right.library?.uri ?? '');
    });
    return matches;
  }

  Future<ClassRef> requireClass(String name, {String? library}) async {
    final matches = await findClasses(
      name: name,
      library: library,
      exact: true,
    );
    if (matches.isEmpty) {
      final libraryArgument = library == null ? '' : ' --library "$library"';
      throw ObjectInspectionException(
        'No loaded class named "$name" was found in isolate $isolateName.',
        next:
            'Run dart-vm object classes --name "$name"$libraryArgument to inspect loaded class names and library URIs.',
      );
    }
    if (matches.length > 1) {
      final libraries = matches
          .map((candidate) => candidate.library?.uri ?? '<unknown library>')
          .join(', ');
      throw ObjectInspectionException(
        'Class "$name" is ambiguous. Matches: $libraries.',
        next:
            'Repeat the command with --library <unique-uri-fragment> to select one class.',
      );
    }
    return matches.single;
  }

  Future<InstanceSet> instances(
    ClassRef classRef, {
    required int limit,
    bool includeSubclasses = false,
    bool includeImplementers = false,
  }) async {
    try {
      return await _service.getInstances(
        isolateId,
        classRef.id!,
        limit,
        includeSubclasses: includeSubclasses,
        includeImplementers: includeImplementers,
      );
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'The VM could not enumerate instances of "${classRef.name}": ${_rpcMessage(error)}.',
        next:
            'Confirm the App is running in Debug or Profile mode. If the App restarted, reconnect with dart-vm service list.',
      );
    }
  }

  Future<ObjRef> requireUniqueInstance(ClassRef classRef) async {
    final result = await instances(classRef, limit: 2);
    final totalCount = result.totalCount ?? 0;
    if (totalCount == 0) {
      throw ObjectInspectionException(
        'Class "${classRef.name}" is loaded but has no live instances in isolate $isolateName.',
        next:
            'Reach the relevant App screen or initialize the feature, then run dart-vm object instances --class "${classRef.name}" again.',
      );
    }
    if (totalCount > 1) {
      final library = classRef.library?.uri;
      final libraryArgument = library == null ? '' : ' --library "$library"';
      throw ObjectInspectionException(
        'Class "${classRef.name}" has $totalCount live instances. VM instance order is unstable, so dart-vm will not select one implicitly.',
        next:
            'Run dart-vm object instances --class "${classRef.name}"$libraryArgument, then inspect a returned object with dart-vm object get --id <object-id>.',
      );
    }
    final instance = result.instances?.singleOrNull;
    if (instance?.id == null) {
      throw ObjectInspectionException(
        'The VM reported one instance of "${classRef.name}" but did not return an object ID.',
        next: 'Run the command again. If it persists, Hot Restart the App.',
      );
    }
    return instance!;
  }

  Future<Obj> getObject(String objectId, {int? offset, int? count}) async {
    try {
      return await _service.getObject(
        isolateId,
        objectId,
        offset: offset,
        count: count,
      );
    } on SentinelException catch (error) {
      throw ObjectInspectionException(
        'Object "$objectId" is unavailable: ${error.sentinel.valueAsString}.',
        next:
            'Object IDs can expire after GC, Hot Restart, or App restart. Run dart-vm object instances again to obtain a current ID.',
      );
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'Object "$objectId" could not be read: ${_rpcMessage(error)}.',
        next:
            'Run dart-vm object instances --class <class-name> to obtain a current object ID, and verify that it belongs to this isolate.',
      );
    }
  }

  Future<dynamic> readPath(ObjRef root, String path) async {
    dynamic current = root;
    for (final segment in parseObjectPath(path)) {
      final objectId = current is ObjRef ? current.id : null;
      if (objectId == null || objectId.isEmpty) {
        throw ObjectInspectionException(
          'Cannot continue at "$segment" because the current value has no object ID.',
          next:
              'Inspect the parent value without the remaining path to see its kind and value.',
        );
      }
      final object = await getObject(objectId, count: 100);
      current = switch (segment) {
        ObjectFieldPathSegment() => _readField(object, segment),
        ObjectBracketPathSegment() => await _readBracket(object, segment),
      };
    }
    return current;
  }

  Future<Obj> loadValue(dynamic value, {int collectionLimit = 20}) async {
    if (value is! ObjRef || value.id == null) {
      throw ObjectInspectionException(
        'The selected value is not an inspectable VM object.',
        next: 'Inspect its parent object to see the raw field reference.',
      );
    }
    if (value is! InstanceRef) {
      return getObject(value.id!, count: collectionLimit);
    }
    final isCollection = const {
      'List',
      'Map',
      'Set',
      'Uint8ClampedList',
      'Uint8List',
      'Uint16List',
      'Uint32List',
      'Uint64List',
      'Int8List',
      'Int16List',
      'Int32List',
      'Int64List',
      'Float32List',
      'Float64List',
      'Int32x4List',
      'Float32x4List',
      'Float64x2List',
    }.contains(value.kind);
    return getObject(value.id!, count: isCollection ? collectionLimit : null);
  }

  Future<void> dispose() => _service.dispose();

  dynamic _readField(Obj object, ObjectFieldPathSegment segment) {
    if (object is! Instance || object.fields == null) {
      throw ObjectInspectionException(
        'Cannot read field "${segment.name}" from ${describeObjectKind(object)}.',
        next:
            'Run dart-vm object get --id "${object.id}" to inspect the current value.',
      );
    }
    for (final field in object.fields!) {
      final fieldName = field.name ?? field.decl?.name;
      if (fieldName?.toString() == segment.name) {
        return field.value;
      }
    }
    final available = object.fields!
        .map((field) => field.name ?? field.decl?.name)
        .whereType<Object>()
        .join(', ');
    throw ObjectInspectionException(
      'Field "${segment.name}" was not found on ${object.classRef?.name ?? describeObjectKind(object)}.${available.isEmpty ? '' : ' Available fields: $available.'}',
      next:
          'Run dart-vm object get --id "${object.id}" to inspect the current fields.',
    );
  }

  Future<dynamic> _readBracket(
    Obj object,
    ObjectBracketPathSegment segment,
  ) async {
    if (object is! Instance) {
      throw ObjectInspectionException(
        'Cannot apply $segment to ${describeObjectKind(object)}.',
        next:
            'Run dart-vm object get --id "${object.id}" to inspect the current value.',
      );
    }
    if (object.kind == 'List') {
      final index = segment.key;
      if (index is! int || index < 0) {
        throw ObjectInspectionException(
          'List access requires a non-negative integer index, but received $segment.',
          next: 'Use a path such as items[0].field.',
        );
      }
      final length = object.length ?? 0;
      if (index >= length) {
        throw ObjectInspectionException(
          'List index $index is out of range for a List of length $length.',
          next: 'Use an index from 0 to ${length - 1}.',
        );
      }
      final page = await getObject(object.id!, offset: index, count: 1);
      final elements = page is Instance ? page.elements : null;
      if (elements == null || elements.isEmpty) {
        throw ObjectInspectionException(
          'The VM did not return List element $index.',
          next:
              'Run the command again; the List may have changed while reading.',
        );
      }
      return elements.single;
    }
    if (object.kind == 'Map') {
      return _readMapValue(object, segment);
    }
    if (object.kind == 'Record' && segment.key is int) {
      for (final field in object.fields ?? const <BoundField>[]) {
        if (field.name == segment.key) return field.value;
      }
    }
    throw ObjectInspectionException(
      'Cannot apply $segment to ${describeObjectKind(object)}.',
      next:
          'Bracket access supports List indexes, Map scalar keys, and positional Record fields.',
    );
  }

  Future<dynamic> _readMapValue(
    Instance map,
    ObjectBracketPathSegment segment,
  ) async {
    const pageSize = 100;
    final length = map.length ?? 0;
    for (var offset = 0; offset < length; offset += pageSize) {
      final page = await getObject(map.id!, offset: offset, count: pageSize);
      final associations = page is Instance
          ? page.associations ?? const <MapAssociation>[]
          : const <MapAssociation>[];
      for (final association in associations) {
        if (await _matchesScalar(association.key, segment.key)) {
          return association.value;
        }
      }
      if (associations.isEmpty) break;
    }
    throw ObjectInspectionException(
      'Map key ${jsonEncode(segment.key)} was not found.',
      next:
          'Run dart-vm object get --id "${map.id}" to inspect the available Map entries.',
    );
  }

  Future<bool> _matchesScalar(dynamic reference, Object? expected) async {
    if (reference is! InstanceRef) return false;
    if (reference.kind == 'Null') return expected == null;
    var value = reference.valueAsString;
    if (reference.valueAsStringIsTruncated == true && reference.id != null) {
      final loaded = await getObject(reference.id!);
      if (loaded is Instance) value = loaded.valueAsString;
    }
    return switch (reference.kind) {
      'String' => expected is String && value == expected,
      'Bool' => expected is bool && (value == 'true') == expected,
      'Int' => expected is int && int.tryParse(value ?? '') == expected,
      'Double' => expected is num && double.tryParse(value ?? '') == expected,
      _ => false,
    };
  }
}

IsolateRef _selectIsolate(List<IsolateRef> isolates, String? selector) {
  if (selector != null && selector.isNotEmpty) {
    for (final isolate in isolates) {
      if (isolate.id == selector || isolate.name == selector) {
        return isolate;
      }
    }
    final available = isolates
        .where((isolate) => isolate.isSystemIsolate != true)
        .map((isolate) => '${isolate.name ?? '<unnamed>'} (${isolate.id})')
        .join(', ');
    throw ObjectInspectionException(
      'No isolate matches "$selector".${available.isEmpty ? '' : ' Available isolates: $available.'}',
      next:
          'Omit --isolate to use main, or pass one of the listed names or IDs.',
    );
  }

  IsolateRef? fallback;
  for (final isolate in isolates) {
    if (isolate.name == 'main' && isolate.id != null) return isolate;
    if (fallback == null &&
        isolate.isSystemIsolate != true &&
        isolate.id != null) {
      fallback = isolate;
    }
  }
  if (fallback != null) return fallback;
  throw ObjectInspectionException(
    'No non-system isolate is available from this VM Service.',
    next:
        'Run dart-vm service list and connect to a running Debug or Profile App.',
  );
}

Map<String, Object?> describeClass(ClassRef classRef) => {
  'id': classRef.id,
  'name': classRef.name,
  'library': classRef.library?.uri,
};

Map<String, Object?> describeReference(dynamic reference) {
  if (reference is Sentinel) {
    return {
      'kind': 'Sentinel',
      'sentinelKind': reference.kind,
      'value': reference.valueAsString,
    };
  }
  if (reference is InstanceRef) {
    return {
      'id': reference.id,
      'kind': reference.kind,
      'class': ?reference.classRef?.name,
      'identityHashCode': ?reference.identityHashCode,
      'length': ?reference.length,
      'value': ?_scalarValue(reference),
      if (reference.kind == 'Null') 'value': null,
      if (reference.valueAsStringIsTruncated == true) 'truncated': true,
    };
  }
  if (reference is ObjRef) {
    return {'id': reference.id, 'type': reference.type};
  }
  return {'value': reference};
}

Map<String, Object?> describeObject(Obj object) {
  if (object is! Instance) {
    return {'id': object.id, 'type': object.type};
  }
  return {
    ...describeReference(object),
    if (object.offset != null) 'offset': object.offset,
    if (object.count != null) 'count': object.count,
    if (object.fields case final fields? when fields.isNotEmpty)
      'fields': object.fields!
          .map(
            (field) => {
              'name': field.name ?? field.decl?.name,
              'value': describeReference(field.value),
            },
          )
          .toList(),
    if (object.elements case final elements? when elements.isNotEmpty)
      'elements': object.elements!.map(describeReference).toList(),
    if (object.associations case final associations?
        when associations.isNotEmpty)
      'entries': object.associations!
          .map(
            (association) => {
              'key': describeReference(association.key),
              'value': describeReference(association.value),
            },
          )
          .toList(),
  };
}

String describeObjectKind(Obj object) {
  if (object is Instance) {
    return object.classRef?.name ?? object.kind ?? 'Instance';
  }
  return object.type;
}

Object? _scalarValue(InstanceRef reference) {
  final value = reference.valueAsString;
  return switch (reference.kind) {
    'String' => value,
    'Bool' => value == null ? null : value == 'true',
    'Int' => value == null ? null : int.tryParse(value) ?? value,
    'Double' => value == null ? null : _finiteDouble(value),
    _ => null,
  };
}

Object _finiteDouble(String value) {
  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite ? parsed : value;
}

String _rpcMessage(RPCError error) {
  final details = error.details;
  return details == null || details.isEmpty
      ? '${error.message} (${error.code})'
      : '${error.message} (${error.code}): $details';
}
