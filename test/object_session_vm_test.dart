import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group(
    'local Dart VM',
    () {
      late Process vm;
      late Directory temp;
      late String uri;
      final fixture = File('test/fixtures/session_room.dart').absolute;
      final lib = fixture.uri.toString();

      setUpAll(() async {
        temp = await Directory.systemTemp.createTemp('dart-vm-session-');
        addTearDown(() => temp.delete(recursive: true));
        final info = File('${temp.path}/service.json');
        vm = await Process.start(Platform.resolvedExecutable, [
          '--enable-vm-service=0',
          '--write-service-info=${info.path}',
          fixture.path,
        ]);
        addTearDown(() async {
          vm.kill();
          await vm.exitCode;
        });
        vm.stdout.drain<void>();
        vm.stderr.drain<void>();
        await (() async {
          while (!await info.exists() || await info.length() == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        })().timeout(const Duration(seconds: 15));
        uri = jsonDecode(await info.readAsString())['uri'] as String;
      });

      Future<ProcessResult> cli(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_vm.dart', '--uri=$uri', 'object', ...args],
      );

      Future<ProcessResult> batch(List<Map<String, Object?>> steps) async {
        final file = File('${temp.path}/steps.jsonl');
        await file.writeAsString(steps.map(jsonEncode).join('\n'));
        return cli(['session', '--file=${file.path}']);
      }

      List<dynamic> rows(ProcessResult p) => const LineSplitter()
          .convert(p.stdout as String)
          .map(jsonDecode)
          .toList();

      test(
        'saves, passes, awaits, inspects and restores the original list',
        () async {
          final result = await batch([
            {
              'class': 'Inbox',
              'expression': 'rooms.toList()',
              'as': 'original',
              'undo': 'rooms..clear()..addAll(previous)',
            },
            {
              'staticClass': 'Room',
              'expression': 'create()',
              'as': 'room',
              'fields': ['name'],
            },
            {
              'libraryUri': lib,
              'expression': 'inbox.closeRoom(room)',
              'scope': {'room': 'room'},
              'await': true,
              'as': 'length',
            },
            {'ref': 'room', 'expression': 'name'},
            {
              'class': 'Inbox',
              'expression': 'this',
              'fields': ['rooms[1].name', 'refreshes'],
            },
            {'restore': 'original'},
            {'libraryUri': lib, 'expression': 'inbox.rooms.single.name'},
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          expect(result.stderr, isEmpty);
          final out = rows(result);
          expect(out, hasLength(7));
          expect(out[1]['fields']['name']['value'], 'preview');
          expect(out[2]['result']['value'], 2);
          expect(out[3]['result']['value'], 'preview');
          expect(out[4]['fields']['rooms[1].name']['value'], 'preview');
          expect(out[4]['fields']['refreshes']['value'], 1);
          expect(out[5]['restored'], 'original');
          expect(out[6]['result']['value'], 'original');
        },
      );

      test(
        'single-shot contexts, asynchronous null and lexical scope',
        () async {
          final cmd = await cli([
            'evaluate',
            '--static-class=Room',
            '--expression=create()',
            '--fields=name',
          ]);
          expect(cmd.exitCode, 0, reason: cmd.stderr.toString());
          expect(
            jsonDecode(cmd.stdout as String)['fields']['name']['value'],
            'preview',
          );
          final result = await batch([
            {
              'libraryUri': lib,
              'expression': 'Future<void>.value()',
              'await': true,
              'as': 'nothing',
            },
            {
              'libraryUri': lib,
              'expression': 'identical(box, null)',
              'scope': {'box': 'nothing'},
              'await': true,
            },
            {
              'staticClass': 'Room',
              'expression': "await Future.value(create())",
              'await': true,
              'fields': ['name'],
            },
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          final out = rows(result);
          expect(out[0]['result'], {'kind': 'Null', 'value': null});
          expect(out[1]['result']['value'], true);
          expect(out[2]['fields']['name']['value'], 'preview');
        },
      );

      test(
        'restores an asynchronously captured value with the original receiver',
        () async {
          final result = await batch([
            {
              'class': 'Inbox',
              'expression': 'Future.value(refreshes)',
              'await': true,
              'as': 'initial',
              'undo': 'Future(() => refreshes = previous)',
            },
            {'class': 'Inbox', 'expression': 'refreshes = 101'},
            {'restore': 'initial', 'await': true},
            {'libraryUri': lib, 'expression': 'inbox.refreshes'},
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          final out = rows(result);
          expect(out[1]['result']['value'], 101);
          expect(out[2]['result'], out[0]['result']);
          expect(out[3]['result'], out[0]['result']);
        },
      );

      test(
        'reports thrown asynchronous errors and never executes the next line',
        () async {
          final result = await batch([
            {'libraryUri': lib, 'expression': '1'},
            {
              'libraryUri': lib,
              'expression': "Future<int>.error(StateError('room closed'))",
              'await': true,
            },
            {'libraryUri': lib, 'expression': "throw 'unreachable'"},
          ]);
          expect(result.exitCode, 1);
          expect(rows(result), hasLength(1));
          final e = jsonDecode(result.stderr as String);
          expect(e['line'], 2);
          expect(e['error']['code'], 'exception');
          expect(e['error']['message'], contains('room closed'));
          expect(e['error']['stack'], isA<String>());
        },
      );

      test('reports timeout; the submitted action executes once', () async {
        final result = await batch([
          {
            'libraryUri': lib,
            'expression':
                "(() { inbox.refreshes = 50; return Completer<int>().future; })()",
            'await': true,
            'timeoutMs': 750,
          },
          {'libraryUri': lib, 'expression': 'inbox.refreshes = 80'},
        ]);
        expect(result.exitCode, 1);
        expect(jsonDecode(result.stderr as String)['error']['code'], 'timeout');
        final check = await cli([
          'evaluate',
          '--library-uri=$lib',
          '--expression=inbox.refreshes',
        ]);
        expect(jsonDecode(check.stdout as String)['result']['value'], 50);
      });
    },
    skip: Platform.environment['DART_VM_SMOKE'] != '1'
        ? 'Set DART_VM_SMOKE=1 to run the isolated VM smoke tests.'
        : false,
  );
}
