import 'package:vm_service/utils.dart';

/// Converts an HTTP(S) VM Service URI to the WebSocket URI required by
/// [vmServiceConnectUri]. WebSocket URIs are returned unchanged.
String normalizeVmServiceUri(String value) {
  final uri = Uri.parse(value);
  return switch (uri.scheme) {
    'http' ||
    'https' => convertToWebSocketUrl(serviceProtocolUrl: uri).toString(),
    'ws' || 'wss' => uri.toString(),
    _ => throw ArgumentError.value(
      value,
      'uri',
      'Expected an http(s) or ws(s) VM Service URI.',
    ),
  };
}
