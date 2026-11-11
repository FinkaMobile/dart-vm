import 'package:dart_vm/dart_vm.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  group('parseObjectPath', () {
    test('parses fields, list indexes, and Map keys', () {
      final segments = parseObjectPath('_store.items[0].settings["endpoint"]');

      expect(segments, hasLength(5));
      expect((segments[0] as ObjectFieldPathSegment).name, '_store');
      expect((segments[1] as ObjectFieldPathSegment).name, 'items');
      expect((segments[2] as ObjectBracketPathSegment).key, 0);
      expect((segments[3] as ObjectFieldPathSegment).name, 'settings');
      expect((segments[4] as ObjectBracketPathSegment).key, 'endpoint');
    });

    test('parses every supported JSON scalar Map key', () {
      final segments = parseObjectPath('["key"][42][1.5][true][null]');

      expect(
        segments.map((segment) => (segment as ObjectBracketPathSegment).key),
        ['key', 42, 1.5, true, null],
      );
    });

    test('parses escaped characters inside a Map key', () {
      final segments = parseObjectPath(r'map["a\"b"]');

      expect((segments[1] as ObjectBracketPathSegment).key, 'a"b');
    });

    test('rejects malformed paths with actionable syntax', () {
      expect(() => parseObjectPath('field.'), throwsFormatException);
      expect(() => parseObjectPath('.field'), throwsFormatException);
      expect(() => parseObjectPath('items[0'), throwsFormatException);
      expect(
        () => parseObjectPath('map[unquoted]'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('["name"]'),
          ),
        ),
      );
    });
  });

  group('parseObjectWhereClause', () {
    test('parses unquoted strings and JSON scalar values', () {
      expect(parseObjectWhereClause('_state._name=connected').toJson(), {
        'path': '_state._name',
        'value': 'connected',
      });
      expect(parseObjectWhereClause('enabled=true').value, isTrue);
      expect(parseObjectWhereClause('attempts=3').value, 3);
      expect(parseObjectWhereClause('label="ready"').value, 'ready');
      expect(parseObjectWhereClause('value=null').value, isNull);
    });

    test('rejects malformed clauses and non-scalar JSON values', () {
      expect(
        () => parseObjectWhereClause('missing-separator'),
        throwsFormatException,
      );
      expect(
        () => parseObjectWhereClause('.state=ready'),
        throwsFormatException,
      );
      expect(
        () => parseObjectWhereClause('value=[1,2]'),
        throwsFormatException,
      );
    });
  });

  test('requires a complete candidate scan even when one instance matched', () {
    final match = ObjectFindMatch(
      instance: InstanceRef(id: 'objects/1/1'),
      values: const {},
      identityHashCode: null,
    );
    ObjectFindResult found({required bool scanComplete}) => ObjectFindResult(
      totalCount: 2,
      scannedCount: scanComplete ? 2 : 1,
      matches: [match],
      expiredCount: 0,
      collectedCount: 0,
      retryCount: 0,
      scanComplete: scanComplete,
    );

    expect(
      found(scanComplete: true).requireUniqueMatch('Counter'),
      same(match),
    );
    expect(
      () => found(scanComplete: false).requireUniqueMatch('Counter'),
      throwsA(isA<ObjectInspectionException>()),
    );
  });

  test('describes classes with the library needed for disambiguation', () {
    final classRef = ClassRef(
      id: 'classes/1',
      name: 'ExampleController',
      library: LibraryRef(
        id: 'libraries/1',
        name: 'controller',
        uri: 'package:example/controller.dart',
      ),
    );

    expect(describeClass(classRef), {
      'id': 'classes/1',
      'name': 'ExampleController',
      'library': 'package:example/controller.dart',
    });
  });

  test('describes scalar references as native JSON values', () {
    expect(
      describeReference(
        InstanceRef(id: 'objects/1', kind: 'Int', valueAsString: '42'),
      ),
      containsPair('value', 42),
    );
    expect(
      describeReference(
        InstanceRef(id: 'objects/2', kind: 'Bool', valueAsString: 'true'),
      ),
      containsPair('value', true),
    );
    expect(
      describeReference(InstanceRef(id: 'objects/3', kind: 'Null')),
      containsPair('value', null),
    );
  });

  test('keeps reference output compact unless verbose is requested', () {
    final reference = InstanceRef(
      id: 'objects/4',
      kind: 'PlainInstance',
      classRef: ClassRef(id: 'classes/4', name: 'Example'),
      identityHashCode: 42,
      length: 7,
    );

    expect(describeReference(reference), {
      'id': 'objects/4',
      'kind': 'PlainInstance',
      'class': 'Example',
    });
    expect(
      describeReference(reference, verbose: true),
      allOf(containsPair('identityHashCode', 42), containsPair('length', 7)),
    );
  });

  test('describes object fields shallowly', () {
    final object = Instance(
      id: 'objects/1',
      kind: 'PlainInstance',
      classRef: ClassRef(id: 'classes/1', name: 'ExampleController'),
      fields: [
        BoundField(
          name: '_state',
          value: InstanceRef(
            id: 'objects/2',
            kind: 'String',
            valueAsString: 'connected',
          ),
        ),
      ],
    );

    expect(
      describeObject(object)['fields'],
      contains(
        allOf(
          containsPair('name', '_state'),
          containsPair('value', containsPair('value', 'connected')),
        ),
      ),
    );
  });

  test('describes schema fields as usable object paths', () {
    final schemaField = ObjectSchemaField(
      field: FieldRef(
        id: 'fields/1',
        name: '_state',
        declaredType: InstanceRef(
          id: 'objects/1',
          kind: 'Type',
          valueAsString: 'State',
        ),
        isFinal: true,
      ),
      owner: ClassRef(
        id: 'classes/1',
        name: 'ExampleController',
        library: LibraryRef(
          id: 'libraries/1',
          uri: 'package:example/controller.dart',
        ),
      ),
    );

    expect(describeSchemaField(schemaField), {
      'path': '_state',
      'declaredType': 'State',
    });
    expect(
      describeSchemaField(schemaField, verbose: true),
      allOf(
        containsPair('owner', 'ExampleController'),
        containsPair('library', 'package:example/controller.dart'),
      ),
    );
  });

  test('suggests the direct path when a field follows a collection', () {
    final error = collectionFieldPathException(
      path: '_conversations._value',
      parentPath: '_conversations',
      collectionKind: 'List',
    );

    expect(error.message, contains('reached a List at "_conversations"'));
    expect(
      error.next,
      'Use --path "_conversations" directly, or select an entry with "_conversations[0]".',
    );
  });

  test('suggests Map entry extraction when a field follows a Map', () {
    final error = collectionFieldPathException(
      path: 'settings._value',
      parentPath: 'settings',
      collectionKind: 'Map',
    );

    expect(error.message, contains('reached a Map at "settings"'));
    expect(
      error.next,
      'Use --path "settings" with --fields <entry-field>, or select a key with "settings["key"]".',
    );
  });

  group('readRowsAdaptively', () {
    ObjectRowsResult page(int offset, int limit, {required int totalCount}) {
      return ObjectRowsResult(
        collectionKind: 'List',
        totalCount: totalCount,
        rows: List.generate(
          limit,
          (index) => ObjectRow(
            index: offset + index,
            key: null,
            item: null,
            values: const {},
          ),
        ),
      );
    }

    test(
      'retries the same page with a smaller size after an expired ID',
      () async {
        final calls = <(int, int)>[];
        var firstAttempt = true;
        var resetCount = 0;
        var refreshCount = 0;

        final result = await readRowsAdaptively(
          rowLimit: 40,
          readPage: (offset, limit) async {
            calls.add((offset, limit));
            if (firstAttempt) {
              firstAttempt = false;
              throw ObjectUnavailableException(
                'expired',
                kind: SentinelKind.kExpired,
              );
            }
            return page(offset, limit, totalCount: 40);
          },
          resetTemporaryIds: () async => resetCount++,
          refreshTarget: () async {
            refreshCount++;
            return true;
          },
        );

        expect(calls, [(0, 32), (0, 16), (16, 16), (32, 8)]);
        expect(result.rows, hasLength(40));
        expect(result.expiredCount, 1);
        expect(result.retryCount, 1);
        expect(resetCount, 1);
        expect(refreshCount, 1);
      },
    );

    test('does not read past the requested row limit', () async {
      final calls = <(int, int)>[];

      final result = await readRowsAdaptively(
        rowLimit: 1,
        readPage: (offset, limit) async {
          calls.add((offset, limit));
          return page(offset, limit, totalCount: 63);
        },
        resetTemporaryIds: () async {},
        refreshTarget: () async => true,
      );

      expect(calls, [(0, 1)]);
      expect(result.rows, hasLength(1));
    });
  });
}
