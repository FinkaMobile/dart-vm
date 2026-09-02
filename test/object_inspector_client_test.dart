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
}
