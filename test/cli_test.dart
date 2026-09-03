import 'dart:io';

import 'package:test/test.dart';

import '../bin/dart_vm.dart';

void main() {
  Future<String> help(List<String> command) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      ...command,
    ]);
    expect(result.exitCode, 0, reason: command.join(' '));
    return result.stdout as String;
  }

  test('exposes network as the top-level capability', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('network'));
    expect(result.stdout, isNot(contains('\n  status')));
  });

  test('lists HTTP profile commands under network', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'network',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, allOf(contains('status'), contains('requests')));
  });

  test('lists the read-only UI commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'ui',
    ]);
    expect(result.exitCode, 0);
    for (final command in [
      'status',
      'tree',
      'details',
      'layout',
      'screenshot',
    ]) {
      expect(result.stdout, contains(command));
    }
  });

  test('lists generic VM Service extension commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'extension',
      'call',
    ]);

    expect(result.exitCode, 0);
    expect(
      result.stdout,
      allOf(
        contains('--name=<name>'),
        contains('--isolate=<isolate>'),
        contains('--param=<key=value>'),
      ),
    );
  });

  test('lists runtime object inspection commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'object',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, allOf(contains('classes'), contains('find')));
    expect(
      result.stdout,
      allOf(
        isNot(contains('\n  instances')),
        isNot(contains('\n  get')),
        isNot(contains('\n  fields')),
        isNot(contains('\n  rows')),
      ),
    );
  });

  test(
    'object find rejects schema combined with a filter before connecting',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/dart_vm.dart',
        'object',
        'find',
        '--class=Runtime',
        '--schema',
        '--where=enabled=true',
      ]);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('--schema cannot be combined'));
    },
  );

  test('object find reports invalid paths before connecting', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'object',
      'find',
      '--class=Runtime',
      '--path=items[unquoted]',
    ]);

    expect(result.exitCode, 64);
    expect(
      result.stderr,
      allOf(contains('Invalid --path'), contains('["name"]')),
    );
  });

  test('parses object find filters and selected fields', () {
    final results = ObjectFindCommand().argParser.parse([
      '--class=Runtime',
      '--where=_state._name=connected',
      '--fields=_state._name,enabled',
    ]);

    expect(results['where'], ['_state._name=connected']);
    expect(results['fields'], '_state._name,enabled');
  });

  test('uses separate object and collection limits for object find', () {
    final defaults = ObjectFindCommand().argParser.parse(['--class=Runtime']);
    final custom = ObjectFindCommand().argParser.parse([
      '--class=Runtime',
      '--match-limit=3',
      '--row-limit=50',
    ]);

    expect(defaults['match-limit'], '1');
    expect(defaults['row-limit'], '100');
    expect(custom['match-limit'], '3');
    expect(custom['row-limit'], '50');
  });

  test('object find validates selected fields before connecting', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'object',
      'find',
      '--class=Runtime',
      '--fields=items[unquoted]',
    ]);

    expect(result.exitCode, 64);
    expect(result.stderr, contains('Invalid --fields path'));
  });

  test('object find validates a collection path before connecting', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'object',
      'find',
      '--class=Runtime',
      '--path=items[unquoted]',
      '--fields=id',
    ]);

    expect(result.exitCode, 64);
    expect(result.stderr, contains('Invalid --path'));
  });

  test('preserves commas in VM Service extension parameter values', () {
    final results = ExtensionCallCommand().argParser.parse([
      '--name=ext.example.mock',
      '--param=responseBody={"status":0,"message":"ok"}',
    ]);

    expect(results['param'], ['responseBody={"status":0,"message":"ok"}']);
  });

  test('lists local VM Service URI configuration commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'config',
      'uri',
    ]);

    expect(result.exitCode, 0);
    expect(
      result.stdout,
      allOf(contains('set'), contains('show'), contains('clear')),
    );
  });

  test('lists locally running VM Service discovery commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'service',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('list'));
  });

  test('documents the required request ID option', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'network',
      'request',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('--id=<request-id>'));
    expect(result.stdout, contains('network requests'));
  });

  test('accepts a negative request ID as an option value', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      '--uri=ws://127.0.0.1:1/ws',
      'network',
      'request',
      '--id=-242378432789',
    ]);

    expect(result.exitCode, isNonZero);
    expect(result.stderr, isNot(contains('short name')));
  });

  test('documents the requests path option value', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/dart_vm.dart',
      'help',
      'network',
      'requests',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('--path=<path-fragment>'));
  });

  test('documents every leaf command and its parameters', () async {
    final cases = <List<String>, List<String>>{
      ['network', 'status']: [],
      ['network', 'on']: [],
      ['network', 'off']: [],
      ['network', 'requests']: ['--path=<path-fragment>'],
      ['network', 'request']: ['--id=<request-id>', '--body'],
      ['extension', 'call']: [
        '--name=<name>',
        '--isolate=<isolate>',
        '--param=<key=value>',
      ],
      ['object', 'classes']: [
        '--name=<text>',
        '--library=<uri-fragment>',
        '--isolate=<isolate>',
      ],
      ['object', 'find']: [
        '--class=<class-name>',
        '--schema',
        '--where=<path=value>',
        '--path=<field-path>',
        '--fields=<path[,path...]>',
        '--match-limit=<count>',
        '--row-limit=<count>',
        '--include-subclasses',
        '--include-implementers',
        '--library=<uri-fragment>',
        '--isolate=<isolate>',
        '--verbose',
      ],
      ['config', 'uri', 'set']: [],
      ['config', 'uri', 'show']: [],
      ['config', 'uri', 'clear']: [],
      ['service', 'list']: [],
      ['upgrade']: ['--check'],
      ['ui', 'status']: [],
      ['ui', 'tree']: [],
      ['ui', 'details']: ['--id=<widget-id>'],
      ['ui', 'layout']: ['--id=<widget-id>', '--depth=<depth>'],
      ['ui', 'screenshot']: [
        '--id=<widget-id>',
        '--width=<px>',
        '--height=<px>',
        '--out=<png-path>',
      ],
    };

    final rootHelp = await help([]);
    expect(
      rootHelp,
      allOf(contains('--uri=<VM_SERVICE_URI>'), contains('--version')),
    );
    for (final entry in cases.entries) {
      final output = await help(entry.key);
      for (final parameter in entry.value) {
        expect(output, contains(parameter), reason: entry.key.join(' '));
      }
    }
  });
}
