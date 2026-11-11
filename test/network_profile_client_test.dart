import 'package:dart_vm/dart_vm.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  group('normalizeVmServiceUri', () {
    test('converts HTTP(S) URIs to WebSocket URIs', () {
      expect(
        normalizeVmServiceUri('http://127.0.0.1:8181/token/'),
        'ws://127.0.0.1:8181/token/ws',
      );
      expect(
        normalizeVmServiceUri('https://example.test/token/'),
        'wss://example.test/token/ws',
      );
      expect(
        normalizeVmServiceUri('http://127.0.0.1:8181'),
        'ws://127.0.0.1:8181/ws',
      );
      expect(
        normalizeVmServiceUri('https://example.test/token/ws?query=1'),
        'wss://example.test/token/ws?query=1',
      );
    });

    test('keeps WebSocket URIs unchanged', () {
      expect(
        normalizeVmServiceUri('ws://127.0.0.1:8181/token/'),
        'ws://127.0.0.1:8181/token/',
      );
    });

    test('rejects unsupported schemes', () {
      expect(
        () => normalizeVmServiceUri('ftp://example.test'),
        throwsArgumentError,
      );
    });
  });

  test('preserves microsecond request durations', () {
    final startedAt = DateTime.utc(2026);
    final summary = summarizeRequest(
      HttpProfileRequestRef(
        id: 'request-1',
        isolateId: 'isolates/main',
        method: 'GET',
        uri: Uri.parse('https://example.test'),
        events: [],
        startTime: startedAt,
        endTime: startedAt.add(const Duration(microseconds: 532)),
      ),
    );

    expect(summary['durationUs'], 532);
    expect(summary['durationMs'], 0.532);
  });
}
