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

class ObjectWhereClause {
  const ObjectWhereClause({required this.path, required this.value});

  final String path;
  final Object? value;

  Map<String, Object?> toJson() => {'path': path, 'value': value};
}

class ObjectFindMatch {
  const ObjectFindMatch({
    required this.instance,
    required this.values,
    required this.identityHashCode,
  });

  final ObjRef instance;
  final Map<String, dynamic> values;
  final int? identityHashCode;
}

class ObjectFindResult {
  const ObjectFindResult({
    required this.totalCount,
    required this.scannedCount,
    required this.matches,
    required this.expiredCount,
    required this.collectedCount,
    required this.retryCount,
  });

  final int totalCount;
  final int scannedCount;
  final List<ObjectFindMatch> matches;
  final int expiredCount;
  final int collectedCount;
  final int retryCount;
}

class ObjectSchemaField {
  const ObjectSchemaField({required this.field, required this.owner});

  final FieldRef field;
  final ClassRef owner;
}

class ObjectRow {
  const ObjectRow({
    required this.index,
    required this.key,
    required this.item,
    required this.values,
  });

  final int index;
  final dynamic key;
  final dynamic item;
  final Map<String, dynamic> values;
}

class ObjectRowsResult {
  const ObjectRowsResult({
    required this.collectionKind,
    required this.totalCount,
    required this.rows,
    this.expiredCount = 0,
    this.retryCount = 0,
  });

  final String? collectionKind;
  final int totalCount;
  final List<ObjectRow> rows;
  final int expiredCount;
  final int retryCount;
}

typedef ObjectRowsPageReader =
    Future<ObjectRowsResult> Function(int offset, int limit);

typedef ObjectRowsTargetRefresher = Future<bool> Function();

/// Reads collection rows within [rowLimit], rebinding the target only after an
/// expired temporary VM object ID.
Future<ObjectRowsResult> readRowsAdaptively({
  required int rowLimit,
  required ObjectRowsPageReader readPage,
  required Future<void> Function() resetTemporaryIds,
  required ObjectRowsTargetRefresher refreshTarget,
}) async {
  const initialPageSize = 32;
  const minimumPageSize = 4;
  const maximumMinimumPageRetries = 1;
  final rows = <ObjectRow>[];
  String? collectionKind;
  var totalCount = 0;
  var pageSize = initialPageSize;
  var expiredCount = 0;
  var retryCount = 0;
  var minimumPageRetries = 0;

  while (rows.length < rowLimit) {
    try {
      final remaining = rowLimit - rows.length;
      final page = await readPage(
        rows.length,
        pageSize < remaining ? pageSize : remaining,
      );
      collectionKind ??= page.collectionKind;
      totalCount = page.totalCount;
      rows.addAll(page.rows);
      minimumPageRetries = 0;
      if (page.rows.isEmpty ||
          rows.length >= rowLimit ||
          rows.length >= totalCount) {
        break;
      }
    } on ObjectUnavailableException catch (error) {
      if (error.kind != SentinelKind.kExpired) rethrow;

      expiredCount++;
      retryCount++;
      if (pageSize > minimumPageSize) {
        pageSize = pageSize > 8 ? pageSize ~/ 2 : minimumPageSize;
      } else if (++minimumPageRetries > maximumMinimumPageRetries) {
        rethrow;
      }

      await resetTemporaryIds();
      if (!await refreshTarget()) {
        throw ObjectUnavailableException(
          'Matched object was collected while its collection was being read.',
          kind: SentinelKind.kCollected,
        );
      }
    }
  }

  return ObjectRowsResult(
    collectionKind: collectionKind,
    totalCount: totalCount,
    rows: rows,
    expiredCount: expiredCount,
    retryCount: retryCount,
  );
}

ObjectWhereClause parseObjectWhereClause(String source) {
  final separator = source.indexOf('=');
  if (separator <= 0) {
    throw FormatException(
      'Invalid where clause "$source". Use path=value, for example _status._name=connected.',
    );
  }
  final path = source.substring(0, separator).trim();
  final rawValue = source.substring(separator + 1).trim();
  try {
    parseObjectPath(path);
  } on FormatException catch (error) {
    throw FormatException('Invalid where path "$path": ${error.message}');
  }
  final value = _parseWhereValue(rawValue);
  return ObjectWhereClause(path: path, value: value);
}

Object? _parseWhereValue(String source) {
  if (source.isEmpty) return '';
  Object? value;
  try {
    value = jsonDecode(source);
  } on FormatException {
    return source;
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw FormatException(
    'Where values must be JSON scalars or unquoted strings, got $source.',
  );
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

class ObjectUnavailableException extends ObjectInspectionException {
  ObjectUnavailableException(super.message, {super.next, required this.kind});

  final String? kind;
}

class ObjectInspectorClient {
  ObjectInspectorClient._(
    this._service,
    this.isolateId,
    this.isolateName,
    this._idZoneId,
  );

  final VmService _service;
  final String isolateId;
  final String isolateName;
  final String? _idZoneId;

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
      String? idZoneId;
      try {
        idZoneId = (await service.createIdZone(
          id,
          'ring',
          'reuseExisting',
          capacity: 16384,
        )).id;
      } on RPCError {
        // Older VM Services can still be inspected with their default ID zone.
      }
      return ObjectInspectorClient._(
        service,
        id,
        detail.name ?? selected.name ?? id,
        idZoneId,
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
        idZoneId: _idZoneId,
      );
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'The VM could not enumerate instances of "${classRef.name}": ${_rpcMessage(error)}.',
        next:
            'Confirm the App is running in Debug or Profile mode. If the App restarted, reconnect with dart-vm service list.',
      );
    }
  }

  Future<ObjectFindResult> findInstances(
    ClassRef classRef, {
    required List<ObjectWhereClause> where,
    required List<String> fields,
    required int limit,
    bool includeSubclasses = false,
    bool includeImplementers = false,
  }) async {
    var retryCount = 0;
    var expiredCount = 0;
    var collectedCount = 0;
    late int totalCount;
    late int scannedCount;
    late List<ObjectFindMatch> matches;

    for (var attempt = 0; attempt < 2; attempt++) {
      var result = await instances(
        classRef,
        limit: limit,
        includeSubclasses: includeSubclasses,
        includeImplementers: includeImplementers,
      );
      var candidates = result.instances ?? const <ObjRef>[];
      totalCount = result.totalCount ?? candidates.length;
      if (where.isNotEmpty && totalCount > candidates.length) {
        result = await instances(
          classRef,
          limit: totalCount,
          includeSubclasses: includeSubclasses,
          includeImplementers: includeImplementers,
        );
        candidates = result.instances ?? const <ObjRef>[];
      }

      final attemptMatches = <ObjectFindMatch>[];
      var attemptExpired = 0;
      var attemptCollected = 0;
      var attemptScanned = 0;
      for (final candidate in candidates) {
        if (attemptMatches.length >= limit) break;
        attemptScanned++;
        try {
          final object = await getObject(candidate.id!, count: 1);
          var matchesWhere = true;
          for (final clause in where) {
            final value = await readPathOrNull(candidate, clause.path);
            if (!await _matchesScalar(value, clause.value)) {
              matchesWhere = false;
              break;
            }
          }
          if (!matchesWhere) continue;

          final values = <String, dynamic>{};
          for (final field in fields) {
            values[field] = await readPathOrNull(candidate, field);
          }
          attemptMatches.add(
            ObjectFindMatch(
              instance: candidate,
              values: values,
              identityHashCode: object is Instance
                  ? object.identityHashCode
                  : null,
            ),
          );
        } on ObjectUnavailableException catch (error) {
          if (error.kind == SentinelKind.kExpired) {
            attemptExpired++;
          } else if (error.kind == SentinelKind.kCollected) {
            attemptCollected++;
          } else {
            rethrow;
          }
        }
      }

      expiredCount += attemptExpired;
      collectedCount += attemptCollected;
      totalCount = result.totalCount ?? totalCount;
      scannedCount = attemptScanned;
      matches = attemptMatches;
      if (attemptExpired == 0) break;
      retryCount++;
    }

    return ObjectFindResult(
      totalCount: totalCount,
      scannedCount: scannedCount,
      matches: matches,
      expiredCount: expiredCount,
      collectedCount: collectedCount,
      retryCount: retryCount,
    );
  }

  Future<List<ObjectSchemaField>> classSchema(ClassRef classRef) async {
    final fields = <ObjectSchemaField>[];
    final visited = <String>{};
    ClassRef? current = classRef;
    while (current != null && current.id != null && visited.add(current.id!)) {
      final currentClass = current;
      final id = currentClass.id!;
      final object = await getObject(id, count: 1);
      if (object is! Class) {
        throw ObjectInspectionException(
          'Class "${currentClass.name}" could not be inspected.',
          next:
              'Run dart-vm object classes --name "${currentClass.name}" to verify the selected class.',
        );
      }
      for (final field in object.fields ?? const <FieldRef>[]) {
        if (field.isStatic != true) {
          fields.add(ObjectSchemaField(field: field, owner: currentClass));
        }
      }
      current = object.superClass;
    }
    return fields;
  }

  Future<ObjectRowsResult> readRows(
    ObjRef root, {
    required String path,
    required List<String> fields,
    required int offset,
    required int limit,
  }) async {
    final selected = await readPath(root, path);
    final collection = await loadValue(selected, collectionLimit: 1);
    if (collection is! Instance ||
        !const {'List', 'Set', 'Map'}.contains(collection.kind)) {
      throw ObjectInspectionException(
        'Path "$path" does not resolve to a List, Set, or Map.',
        next:
            'Run dart-vm object find with the same class and --path "$path" to inspect the selected value.',
      );
    }

    final totalCount = collection.length ?? 0;
    if (offset >= totalCount) {
      return ObjectRowsResult(
        collectionKind: collection.kind,
        totalCount: totalCount,
        rows: const <ObjectRow>[],
      );
    }
    final count = offset + limit > totalCount ? totalCount - offset : limit;
    final page = await getObject(collection.id!, offset: offset, count: count);
    final entries = collection.kind == 'Map'
        ? (page is Instance
                  ? page.associations ?? const <MapAssociation>[]
                  : const <MapAssociation>[])
              .map((entry) => (key: entry.key, value: entry.value))
        : (page is Instance ? page.elements ?? const <dynamic>[] : const [])
              .map((entry) => (key: null, value: entry));
    final rows = <ObjectRow>[];
    for (final entry in entries) {
      final values = <String, dynamic>{};
      for (final field in fields) {
        values[field] = entry.value is ObjRef
            ? await readPathOrNull(entry.value, field)
            : null;
      }
      rows.add(
        ObjectRow(
          index: offset + rows.length,
          key: entry.key,
          item: entry.value,
          values: values,
        ),
      );
    }
    return ObjectRowsResult(
      collectionKind: collection.kind,
      totalCount: totalCount,
      rows: rows,
    );
  }

  Future<Obj> getObject(String objectId, {int? offset, int? count}) async {
    try {
      return await _service.getObject(
        isolateId,
        objectId,
        offset: offset,
        count: count,
        idZoneId: _idZoneId,
      );
    } on SentinelException catch (error) {
      throw ObjectUnavailableException(
        'Object "$objectId" is unavailable: ${error.sentinel.valueAsString}.',
        kind: error.sentinel.kind,
        next:
            'Object IDs can expire after GC, Hot Restart, or App restart. Repeat the same dart-vm object find command to locate the object again.',
      );
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'Object "$objectId" could not be read: ${_rpcMessage(error)}.',
        next:
            'Repeat the same dart-vm object find command. If it persists, verify the class with dart-vm object classes --name <class-name>.',
      );
    }
  }

  Future<void> resetTemporaryIds() async {
    if (_idZoneId == null) return;
    try {
      await _service.invalidateIdZone(isolateId, _idZoneId);
    } on RPCError catch (error) {
      throw ObjectInspectionException(
        'The VM could not reset temporary object IDs: ${_rpcMessage(error)}.',
        next: 'Repeat the same dart-vm object find command.',
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

  /// Reads a path while treating a missing field, null parent, or out-of-range
  /// collection entry as no match. VM protocol failures still propagate.
  Future<dynamic> readPathOrNull(ObjRef root, String path) async {
    dynamic current = root;
    for (final segment in parseObjectPath(path)) {
      if (current is InstanceRef && current.kind == 'Null') return null;
      final objectId = current is ObjRef ? current.id : null;
      if (objectId == null || objectId.isEmpty) return null;
      final object = await getObject(objectId, count: 100);
      current = switch (segment) {
        ObjectFieldPathSegment() => _findField(object, segment),
        ObjectBracketPathSegment() => await _readBracketOrNull(object, segment),
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

  Future<void> dispose() async {
    if (_idZoneId != null) {
      try {
        await _service.deleteIdZone(isolateId, _idZoneId);
      } on RPCError {
        // The VM has already discarded the temporary inspection zone.
      }
    }
    await _service.dispose();
  }

  dynamic _readField(Obj object, ObjectFieldPathSegment segment) {
    if (object is! Instance || object.fields == null) {
      throw ObjectInspectionException(
        'Cannot read field "${segment.name}" from ${describeObjectKind(object)}.',
        next:
            'Run dart-vm object find with the same --class and a shorter --path to inspect the parent value.',
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
          'Run dart-vm object find --class <class-name> --schema to inspect supported field paths.',
    );
  }

  dynamic _findField(Obj object, ObjectFieldPathSegment segment) {
    if (object is! Instance || object.fields == null) return null;
    for (final field in object.fields!) {
      final fieldName = field.name ?? field.decl?.name;
      if (fieldName?.toString() == segment.name) return field.value;
    }
    return null;
  }

  Future<dynamic> _readBracket(
    Obj object,
    ObjectBracketPathSegment segment,
  ) async {
    if (object is! Instance) {
      throw ObjectInspectionException(
        'Cannot apply $segment to ${describeObjectKind(object)}.',
        next:
            'Run dart-vm object find with the same --class and a shorter --path to inspect the parent value.',
      );
    }
    if (object.kind == 'List' || object.kind == 'Set') {
      final index = segment.key;
      if (index is! int || index < 0) {
        throw ObjectInspectionException(
          'List or Set access requires a non-negative integer index, but received $segment.',
          next: 'Use a path such as items[0].field.',
        );
      }
      final length = object.length ?? 0;
      if (index >= length) {
        throw ObjectInspectionException(
          'Collection index $index is out of range for a collection of length $length.',
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

  Future<dynamic> _readBracketOrNull(
    Obj object,
    ObjectBracketPathSegment segment,
  ) async {
    if (object is! Instance) return null;
    if (object.kind == 'List' || object.kind == 'Set') {
      final index = segment.key;
      if (index is! int || index < 0) return null;
      final length = object.length ?? 0;
      if (index >= length) return null;
      final page = await getObject(object.id!, offset: index, count: 1);
      final elements = page is Instance ? page.elements : null;
      return elements == null || elements.isEmpty ? null : elements.single;
    }
    if (object.kind == 'Map') {
      return _readMapValueOrNull(object, segment);
    }
    if (object.kind == 'Record' && segment.key is int) {
      for (final field in object.fields ?? const <BoundField>[]) {
        if (field.name == segment.key) return field.value;
      }
    }
    return null;
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
          'Run dart-vm object find with the same --class and --path to inspect the available Map entries.',
    );
  }

  Future<dynamic> _readMapValueOrNull(
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
    return null;
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

Map<String, Object?> describeSchemaField(
  ObjectSchemaField item, {
  bool verbose = false,
}) => {
  'path': item.field.name,
  'declaredType':
      item.field.declaredType?.valueAsString ??
      item.field.declaredType?.classRef?.name,
  if (verbose) 'owner': item.owner.name,
  if (verbose) 'library': item.owner.library?.uri,
  if (verbose) 'final': item.field.isFinal,
};

Map<String, Object?> describeReference(
  dynamic reference, {
  bool verbose = false,
}) {
  if (reference is Sentinel) {
    final result = <String, Object?>{
      'kind': 'Sentinel',
      'sentinelKind': reference.kind,
      'value': reference.valueAsString,
    };
    if (!verbose) result.remove('sentinelKind');
    return result;
  }
  if (reference is InstanceRef) {
    final result = <String, Object?>{
      'kind': reference.kind,
      if (_isScalarKind(reference.kind)) 'value': ?_scalarValue(reference),
      if (!_isScalarKind(reference.kind)) 'id': reference.id,
      if (!_isScalarKind(reference.kind)) 'class': ?reference.classRef?.name,
      if (!_isScalarKind(reference.kind) &&
          _isCollectionKind(reference.kind) &&
          reference.length != null)
        'length': reference.length,
      if (reference.kind == 'Null') 'value': null,
      if (reference.valueAsStringIsTruncated == true) 'truncated': true,
    };
    if (verbose) {
      result['identityHashCode'] = reference.identityHashCode;
      if (reference.length != null) result['length'] = reference.length;
    }
    return result;
  }
  if (reference is ObjRef) {
    return {'id': reference.id, 'type': reference.type};
  }
  return {'value': reference};
}

Map<String, Object?> describeObject(Obj object, {bool verbose = false}) {
  if (object is! Instance) {
    return {
      'id': object.id,
      'type': object.type,
      if (verbose) 'metadata': object.toJson(),
    };
  }
  return {
    ...describeReference(object, verbose: verbose),
    if (object.offset != null) 'offset': object.offset,
    if (object.count != null) 'count': object.count,
    if (object.fields case final fields? when fields.isNotEmpty)
      'fields': object.fields!
          .map(
            (field) => {
              'name': field.name ?? field.decl?.name,
              'value': describeReference(field.value, verbose: verbose),
            },
          )
          .toList(),
    if (object.elements case final elements? when elements.isNotEmpty)
      'elements': object.elements!
          .map((element) => describeReference(element, verbose: verbose))
          .toList(),
    if (object.associations case final associations?
        when associations.isNotEmpty)
      'entries': object.associations!
          .map(
            (association) => {
              'key': describeReference(association.key, verbose: verbose),
              'value': describeReference(association.value, verbose: verbose),
            },
          )
          .toList(),
  };
}

bool _isScalarKind(String? kind) =>
    const {'Null', 'Bool', 'Double', 'Int', 'String'}.contains(kind);

bool _isCollectionKind(String? kind) => const {
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
}.contains(kind);

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
