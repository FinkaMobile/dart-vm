import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef _ReleaseStatus = ({
  String current,
  String latest,
  String tag,
  bool available,
});

class ReleaseUpdater {
  ReleaseUpdater({
    required this.currentVersion,
    Uri? latestReleaseUri,
    Uri? releaseDownloadBaseUri,
    String? executablePath,
    String? assetName,
  }) : latestReleaseUri =
           latestReleaseUri ??
           Uri.parse(
             'https://api.github.com/repos/kuopenx/dart-vm/releases/latest',
           ),
       releaseDownloadBaseUri =
           releaseDownloadBaseUri ??
           Uri.parse('https://github.com/kuopenx/dart-vm/releases/download/'),
       executablePath = executablePath ?? Platform.resolvedExecutable,
       assetName = assetName ?? platformAssetName();

  final String currentVersion;
  final Uri latestReleaseUri;
  final Uri releaseDownloadBaseUri;
  final String executablePath;
  final String assetName;

  Future<Map<String, Object>> check() async {
    final status = await _status();
    return {
      'currentVersion': status.current,
      'latestVersion': status.latest,
      'updateAvailable': status.available,
    };
  }

  Future<_ReleaseStatus> _status() async {
    final response = jsonDecode(await _readText(latestReleaseUri));
    if (response is! Map<String, dynamic> || response['tag_name'] is! String) {
      throw const FormatException('Latest GitHub release has no tag_name.');
    }
    final latestTag = response['tag_name'] as String;
    final latestVersion = normalizeVersion(latestTag);
    final normalizedCurrent = normalizeVersion(currentVersion);
    return (
      current: normalizedCurrent,
      latest: latestVersion,
      tag: latestTag,
      available: compareVersions(latestVersion, normalizedCurrent) > 0,
    );
  }

  Future<Map<String, Object>> upgrade() async {
    final status = await _status();
    if (!status.available) {
      return {
        'updated': false,
        'previousVersion': status.current,
        'version': status.current,
      };
    }

    final target = await _resolveExecutable();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'dart-vm-upgrade-',
    );
    try {
      final archive = File(
        '${tempDirectory.path}${Platform.pathSeparator}$assetName',
      );
      final releaseRoot = releaseDownloadBaseUri.resolve('${status.tag}/');
      await _get(releaseRoot.resolve(assetName), destination: archive);

      final checksums = await _readText(releaseRoot.resolve('checksums.txt'));
      final expected = checksumForAsset(checksums, assetName);
      final actual = (await sha256.bind(archive.openRead()).first).toString();
      if (actual != expected) {
        throw StateError(
          'Checksum mismatch for $assetName: expected $expected, got $actual.',
        );
      }

      final extracted = await _extractArchive(archive, tempDirectory);
      await _replaceExecutable(extracted, target);
      return {
        'updated': true,
        'previousVersion': status.current,
        'version': status.latest,
      };
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  }

  Future<File> _resolveExecutable() async {
    final executable = File(executablePath);
    if (!await executable.exists()) {
      throw StateError('Current executable does not exist: $executablePath');
    }
    final resolved = File(await executable.resolveSymbolicLinks());
    final expectedName = Platform.isWindows ? 'dart-vm.exe' : 'dart-vm';
    if (_basename(resolved.path) != expectedName) {
      throw StateError(
        'Self-upgrade requires the compiled $expectedName executable. '
        'Install it first with the release installer.',
      );
    }
    return resolved;
  }

  Future<File> _extractArchive(File archive, Directory tempDirectory) async {
    final extractDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}extract',
    );
    await extractDirectory.create();
    final ProcessResult result;
    if (Platform.isWindows) {
      final archivePath = _powerShellLiteral(archive.path);
      final destinationPath = _powerShellLiteral(extractDirectory.path);
      result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"$ErrorActionPreference = 'Stop'; "
            'Add-Type -AssemblyName System.IO.Compression.FileSystem; '
            '[System.IO.Compression.ZipFile]::ExtractToDirectory('
            '$archivePath, $destinationPath)',
      ]);
    } else {
      result = await Process.run('unzip', [
        '-q',
        archive.path,
        '-d',
        extractDirectory.path,
      ]);
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Could not extract $assetName: ${result.stderr.toString().trim()}',
      );
    }

    final binaryName = Platform.isWindows ? 'dart-vm.exe' : 'dart-vm';
    final binary = File(
      '${extractDirectory.path}${Platform.pathSeparator}$binaryName',
    );
    if (!await binary.exists()) {
      throw StateError('$binaryName was not found in $assetName.');
    }
    return binary;
  }

  Future<void> _replaceExecutable(File source, File target) async {
    final temporary = File('${target.path}.new');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    await source.copy(temporary.path);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['755', temporary.path]);
      if (chmod.exitCode != 0) {
        await temporary.delete();
        throw StateError(
          'Could not make the update executable: '
          '${chmod.stderr.toString().trim()}',
        );
      }
      await temporary.rename(target.path);
      return;
    }

    final backup = File('${target.path}.old');
    if (await backup.exists()) {
      await backup.delete();
    }
    await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } catch (_) {
      await backup.rename(target.path);
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // Windows can keep the running executable locked until this process exits.
    }
  }

  Future<String> _readText(Uri uri) async {
    final bytes = await _get(uri);
    return utf8.decode(bytes);
  }

  Future<List<int>> _get(Uri uri, {File? destination}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'dart-vm/$currentVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GET $uri returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      if (destination != null) {
        await response.pipe(destination.openWrite());
        return const [];
      }
      return await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
    } finally {
      client.close(force: true);
    }
  }

  static String platformAssetName() {
    return switch (Abi.current()) {
      Abi.macosArm64 => 'dart-vm-darwin-arm64.zip',
      Abi.macosX64 => 'dart-vm-darwin-amd64.zip',
      Abi.linuxX64 => 'dart-vm-linux-amd64.zip',
      Abi.windowsX64 => 'dart-vm-windows-amd64.zip',
      final abi => throw UnsupportedError(
        'No released dart-vm binary for $abi.',
      ),
    };
  }

  static String checksumForAsset(String checksums, String assetName) {
    for (final line in const LineSplitter().convert(checksums)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields[1] == assetName) {
        final checksum = fields[0].toLowerCase();
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
          return checksum;
        }
        throw FormatException('Invalid SHA-256 checksum for $assetName.');
      }
    }
    throw FormatException('No checksum found for $assetName.');
  }

  static String normalizeVersion(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid release version: $value');
    }
    return '${match[1]}.${match[2]}.${match[3]}';
  }

  static int compareVersions(String left, String right) {
    final leftParts = normalizeVersion(left).split('.').map(int.parse).toList();
    final rightParts = normalizeVersion(
      right,
    ).split('.').map(int.parse).toList();
    for (var index = 0; index < leftParts.length; index++) {
      final comparison = leftParts[index].compareTo(rightParts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static String _basename(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .last;

  static String _powerShellLiteral(String value) =>
      "'${value.replaceAll("'", "''")}'";
}
