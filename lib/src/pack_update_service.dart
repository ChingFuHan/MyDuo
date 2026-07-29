import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'dictionary_repository.dart';
import 'models.dart';

class PackArtifact {
  const PackArtifact({
    required this.kind,
    required this.format,
    required this.url,
    required this.sha256,
    required this.size,
    required this.version,
    required this.fromVersion,
    required this.accent,
  });

  final String kind;
  final String format;
  final String url;
  final String sha256;
  final int size;
  final String version;
  final String fromVersion;
  final String accent;

  factory PackArtifact.fromJson(Map<String, Object?> json) {
    return PackArtifact(
      kind: json['kind'] as String? ?? '',
      format: json['format'] as String? ?? '',
      url: json['url'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      version: json['version'] as String? ?? '',
      fromVersion: json['from_version'] as String? ?? '',
      accent: json['accent'] as String? ?? '',
    );
  }
}

class PackManifest {
  const PackManifest({
    required this.schema,
    required this.version,
    required this.createdAt,
    required this.artifacts,
    required this.sources,
  });

  final int schema;
  final String version;
  final DateTime createdAt;
  final List<PackArtifact> artifacts;
  final List<Map<String, Object?>> sources;

  factory PackManifest.fromBytes(Uint8List bytes) {
    final json = _map(jsonDecode(utf8.decode(bytes)));
    final manifest = PackManifest(
      schema: (json['schema'] as num?)?.toInt() ?? 0,
      version: json['version'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      artifacts: (json['artifacts'] as List<Object?>? ?? const <Object?>[])
          .map(_map)
          .map(PackArtifact.fromJson)
          .toList(growable: false),
      sources: (json['sources'] as List<Object?>? ?? const <Object?>[])
          .map(_map)
          .toList(growable: false),
    );
    if (manifest.schema != 1 ||
        manifest.version.isEmpty ||
        manifest.artifacts.isEmpty ||
        manifest.sources.any(
          (source) =>
              (source['name'] as String? ?? '').isEmpty ||
              (source['license'] as String? ?? '').isEmpty ||
              (source['url'] as String? ?? '').isEmpty ||
              (source['dump_date'] as String? ?? '').isEmpty ||
              (source['attribution'] as String? ?? '').isEmpty,
        )) {
      throw const FormatException(
          'Pack manifest is incomplete or unsupported.');
    }
    return manifest;
  }
}

class PackUpdateService {
  PackUpdateService({
    required this.repository,
    required this.publicKeyBase64,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final DictionaryRepository repository;
  final String publicKeyBase64;
  final http.Client _client;
  final Ed25519 _ed25519 = Ed25519();

  Future<PackManifest> verifyManifest(
    Uint8List manifestBytes,
    String detachedSignatureBase64,
  ) async {
    if (publicKeyBase64.trim().isEmpty) {
      throw StateError(
        'No Ed25519 pack public key configured. Set '
        'MYDUO_PACK_PUBLIC_KEY with --dart-define.',
      );
    }
    final publicKey = SimplePublicKey(
      base64Decode(publicKeyBase64.trim()),
      type: KeyPairType.ed25519,
    );
    final signature = Signature(
      base64Decode(detachedSignatureBase64.trim()),
      publicKey: publicKey,
    );
    final valid = await _ed25519.verify(
      manifestBytes,
      signature: signature,
    );
    if (!valid) {
      throw const FormatException('Manifest Ed25519 signature is invalid.');
    }
    return PackManifest.fromBytes(manifestBytes);
  }

  Future<PackManifest> check(Uri manifestUri) async {
    _requireSecureUri(manifestUri);
    final manifestResponse = await _client.get(manifestUri);
    if (manifestResponse.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Manifest download failed: HTTP ${manifestResponse.statusCode}',
        uri: manifestUri,
      );
    }
    final signatureUri = manifestUri.replace(
      path: '${manifestUri.path}.sig',
    );
    final signatureResponse = await _client.get(signatureUri);
    if (signatureResponse.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Manifest signature download failed: '
        'HTTP ${signatureResponse.statusCode}',
        uri: signatureUri,
      );
    }
    return verifyManifest(
      manifestResponse.bodyBytes,
      signatureResponse.body.trim(),
    );
  }

  Future<PackInfo> install(Uri manifestUri) async {
    final manifest = await check(manifestUri);
    if (manifest.version == repository.activePack.version) {
      return repository.activePack;
    }

    final delta = manifest.artifacts.where(
      (artifact) =>
          artifact.kind == 'dictionary-delta' &&
          artifact.fromVersion == repository.activePack.version &&
          artifact.version == manifest.version,
    );
    final full = manifest.artifacts.where(
      (artifact) =>
          artifact.kind == 'dictionary-full' &&
          artifact.version == manifest.version,
    );
    final dictionaryArtifact = delta.isNotEmpty
        ? delta.first
        : full.isNotEmpty
            ? full.first
            : throw const FormatException(
                'Manifest has no compatible dictionary artifact.',
              );

    final staging = Directory(
      p.join(
        repository.dataRoot.path,
        'downloads',
        '${manifest.version}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await staging.create(recursive: true);
    final downloadedDictionary = await _downloadArtifact(
      manifestUri,
      dictionaryArtifact,
      staging,
    );

    final File preparedDictionary;
    if (dictionaryArtifact.kind == 'dictionary-delta') {
      if (dictionaryArtifact.format != 'jsonl') {
        throw const FormatException('Delta artifact must use jsonl format.');
      }
      preparedDictionary = await repository.applyDeltaToStaging(
        downloadedDictionary,
        manifest.version,
      );
    } else {
      if (dictionaryArtifact.format != 'sqlite') {
        throw const FormatException(
          'Full dictionary artifact must use sqlite format.',
        );
      }
      preparedDictionary = downloadedDictionary;
    }

    final audioArtifacts = manifest.artifacts.where(
      (artifact) =>
          artifact.kind == 'audio' && artifact.version == manifest.version,
    );
    final stagedAudio = <({PackArtifact artifact, Directory directory})>[];
    for (final artifact in audioArtifacts) {
      if (artifact.format != 'zip') {
        throw const FormatException('Audio artifact must use zip format.');
      }
      final archive = await _downloadArtifact(manifestUri, artifact, staging);
      final output = Directory(
        p.join(staging.path, 'audio-${artifact.accent}'),
      );
      await _extractZipSafely(archive, output);
      await _validateAudioPack(
        output,
        manifest.version,
        artifact.accent,
      );
      stagedAudio.add((artifact: artifact, directory: output));
    }

    final oldPack = repository.activePack;
    try {
      await repository.activatePreparedDatabase(
        preparedDictionary,
        manifest.version,
      );
      await _activateAudioPacks(stagedAudio, manifest.version);
    } catch (_) {
      if (repository.activePack.version != oldPack.version) {
        await repository.reactivate(oldPack);
      }
      rethrow;
    }
    return repository.activePack;
  }

  Future<File> _downloadArtifact(
    Uri manifestUri,
    PackArtifact artifact,
    Directory staging,
  ) async {
    if (artifact.url.isEmpty ||
        artifact.sha256.length != 64 ||
        artifact.size <= 0) {
      throw const FormatException('Artifact metadata is incomplete.');
    }
    final uri = manifestUri.resolve(artifact.url);
    _requireSecureUri(uri);
    final safeName =
        '${artifact.kind}-${artifact.accent}-${artifact.version}.${artifact.format}';
    final destination = File(p.join(staging.path, safeName));
    await _downloadWithResume(uri, destination, artifact.size);
    final digest = await sha256.bind(destination.openRead()).first;
    if (digest.toString().toLowerCase() != artifact.sha256.toLowerCase()) {
      throw const FormatException('Artifact SHA-256 mismatch.');
    }
    return destination;
  }

  Future<void> _downloadWithResume(
    Uri uri,
    File destination,
    int expectedSize,
  ) async {
    final partial = File('${destination.path}.part');
    var existing = await partial.exists() ? await partial.length() : 0;
    if (existing > expectedSize) {
      await partial.writeAsBytes(const <int>[], flush: true);
      existing = 0;
    }
    if (existing == expectedSize) {
      await partial.rename(destination.path);
      return;
    }

    final request = http.Request('GET', uri);
    if (existing > 0) {
      request.headers[HttpHeaders.rangeHeader] = 'bytes=$existing-';
    }
    final response = await _client.send(request);
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'Artifact download failed: HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    if (existing > 0 && response.statusCode == HttpStatus.ok) {
      await partial.writeAsBytes(const <int>[], flush: true);
      existing = 0;
    }
    final sink = partial.openWrite(
      mode: existing > 0 ? FileMode.append : FileMode.write,
    );
    await response.stream.pipe(sink);
    final actual = await partial.length();
    if (actual != expectedSize) {
      throw HttpException(
        'Artifact size mismatch: expected $expectedSize, got $actual',
        uri: uri,
      );
    }
    if (await destination.exists()) {
      await destination.delete();
    }
    await partial.rename(destination.path);
  }

  Future<void> _extractZipSafely(File archiveFile, Directory output) async {
    await output.create(recursive: true);
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input, verify: true);
      for (final member in archive.files) {
        final normalized = p.normalize(p.join(output.path, member.name));
        if (!p.isWithin(output.path, normalized)) {
          throw const FormatException('Audio archive contains unsafe path.');
        }
        if (member.isFile) {
          await Directory(p.dirname(normalized)).create(recursive: true);
          final outputStream = OutputFileStream(normalized);
          member.writeContent(outputStream);
          await outputStream.close();
        } else {
          await Directory(normalized).create(recursive: true);
        }
      }
    } finally {
      await input.close();
    }
  }

  Future<void> _validateAudioPack(
    Directory directory,
    String version,
    String accent,
  ) async {
    if (accent != 'uk' && accent != 'us') {
      throw const FormatException('Audio pack accent must be uk or us.');
    }
    final manifestFile = File(p.join(directory.path, 'audio_manifest.json'));
    if (!await manifestFile.exists()) {
      throw const FormatException('Audio pack manifest is missing.');
    }
    final document = _map(jsonDecode(await manifestFile.readAsString()));
    if (document['schema'] != 1 || document['version'] != version) {
      throw const FormatException('Audio pack manifest is incompatible.');
    }
    final files = document['files'] as List<Object?>? ?? const <Object?>[];
    for (final raw in files) {
      final record = _map(raw);
      if (record['accent'] != accent ||
          (record['license'] as String? ?? '').isEmpty ||
          (record['source_url'] as String? ?? '').isEmpty) {
        throw const FormatException(
          'Audio file provenance is incomplete.',
        );
      }
      final relative = record['path'] as String? ?? '';
      final absolute = p.normalize(p.join(directory.path, relative));
      if (relative.isEmpty || !p.isWithin(directory.path, absolute)) {
        throw const FormatException('Audio manifest path is unsafe.');
      }
      final file = File(absolute);
      final expectedSize = (record['size'] as num?)?.toInt() ?? -1;
      if (!await file.exists() || await file.length() != expectedSize) {
        throw const FormatException('Audio file size is invalid.');
      }
      final expectedHash = record['sha256'] as String? ?? '';
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != expectedHash.toLowerCase()) {
        throw const FormatException('Audio file SHA-256 is invalid.');
      }
    }
  }

  Future<void> _activateAudioPacks(
    List<({PackArtifact artifact, Directory directory})> staged,
    String version,
  ) async {
    if (staged.isEmpty) {
      return;
    }
    final audioRoot = Directory(p.join(repository.dataRoot.path, 'audio'));
    await audioRoot.create(recursive: true);
    final activated = <String, String>{};
    for (final item in staged) {
      final destination = Directory(
        p.join(audioRoot.path, version, item.artifact.accent),
      );
      await destination.parent.create(recursive: true);
      if (await destination.exists()) {
        await _deleteWithinDataRoot(destination);
      }
      await item.directory.rename(destination.path);
      activated[item.artifact.accent] =
          p.relative(destination.path, from: repository.dataRoot.path);
    }
    final pointer = File(p.join(repository.dataRoot.path, 'audio-active.json'));
    final temporary = File('${pointer.path}.new');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        <String, Object?>{
          'version': version,
          'packs': activated,
          'activated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
      flush: true,
    );
    if (await pointer.exists()) {
      final backup = File('${pointer.path}.bak');
      if (await backup.exists()) {
        await backup.delete();
      }
      await pointer.rename(backup.path);
      try {
        await temporary.rename(pointer.path);
        await backup.delete();
      } catch (_) {
        await backup.rename(pointer.path);
        rethrow;
      }
    } else {
      await temporary.rename(pointer.path);
    }
  }

  Future<void> _deleteWithinDataRoot(Directory directory) async {
    final root = p.canonicalize(repository.dataRoot.path);
    final target = p.canonicalize(directory.path);
    if (!p.isWithin(root, target)) {
      throw StateError('Refusing to delete outside app data root.');
    }
    await directory.delete(recursive: true);
  }

  static void _requireSecureUri(Uri uri) {
    final local = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (uri.scheme != 'https' && !(local && uri.scheme == 'http')) {
      throw ArgumentError.value(uri, 'uri', 'HTTPS is required.');
    }
  }

  void dispose() => _client.close();
}

Map<String, Object?> _map(Object? raw) {
  if (raw is! Map<Object?, Object?>) {
    return <String, Object?>{};
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}
