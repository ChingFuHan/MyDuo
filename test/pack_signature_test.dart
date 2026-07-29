import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myduo/src/dictionary_repository.dart';
import 'package:myduo/src/pack_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Ed25519 accepts authentic manifest and rejects tampering', () async {
    final temporary =
        await Directory.systemTemp.createTemp('myduo-signature-test-');
    final repository = await DictionaryRepository.open(
      dataRoot: temporary,
      seedEntries: _minimalEntries,
    );
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'version': 'test-2',
          'created_at': '2026-01-01T00:00:00Z',
          'sources': <Object?>[
            <String, Object?>{
              'name': 'Test',
              'url': 'https://example.invalid',
              'license': 'CC0-1.0',
              'dump_date': '2026-01-01',
              'attribution': 'Test author',
            },
          ],
          'artifacts': <Object?>[
            <String, Object?>{
              'kind': 'dictionary-full',
              'format': 'sqlite',
              'url': 'dictionary.sqlite',
              'sha256': List<String>.filled(64, '0').join(),
              'size': 1,
              'version': 'test-2',
            },
          ],
        }),
      ),
    );
    final signature = await algorithm.sign(manifest, keyPair: keyPair);
    final updater = PackUpdateService(
      repository: repository,
      publicKeyBase64: base64Encode(publicKey.bytes),
    );

    final parsed = await updater.verifyManifest(
      manifest,
      base64Encode(signature.bytes),
    );
    expect(parsed.version, 'test-2');

    final tampered = Uint8List.fromList(manifest)..[10] ^= 1;
    expect(
      updater.verifyManifest(tampered, base64Encode(signature.bytes)),
      throwsA(isA<FormatException>()),
    );

    updater.dispose();
    repository.dispose();
    await temporary.delete(recursive: true);
  });

  test('signed full pack downloads and activates atomically', () async {
    final temporary =
        await Directory.systemTemp.createTemp('myduo-update-test-');
    final repository = await DictionaryRepository.open(
      dataRoot: temporary,
      seedEntries: _minimalEntries,
    );
    final delta = File('${temporary.path}${Platform.pathSeparator}delta.jsonl');
    await delta.writeAsString(
      '${jsonEncode(<String, Object?>{
            'op': 'upsert',
            'entry': <String, Object?>{
              'headword': 'cloud',
              'source': 'Test',
              'source_url': 'https://example.invalid',
              'license': 'CC0-1.0',
              'attribution': 'Test author',
              'senses': <Object?>[
                <String, Object?>{
                  'pos': 'noun',
                  'definition': 'A visible mass of water drops.',
                  'translation_zh': '雲',
                },
              ],
            },
          })}\n',
    );
    final fullDatabase = await repository.applyDeltaToStaging(delta, 'test-2');
    final databaseBytes = await fullDatabase.readAsBytes();

    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final manifestBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'version': 'test-2',
          'created_at': '2026-01-01T00:00:00Z',
          'sources': <Object?>[
            <String, Object?>{
              'name': 'Test',
              'url': 'https://example.invalid',
              'license': 'CC0-1.0',
              'dump_date': '2026-01-01',
              'attribution': 'Test author',
            },
          ],
          'artifacts': <Object?>[
            <String, Object?>{
              'kind': 'dictionary-full',
              'format': 'sqlite',
              'url': 'dictionary.sqlite',
              'sha256': sha256.convert(databaseBytes).toString(),
              'size': databaseBytes.length,
              'version': 'test-2',
            },
          ],
        }),
      ),
    );
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
    final client = MockClient((request) async {
      return switch (request.url.path) {
        '/manifest.json' => http.Response.bytes(manifestBytes, HttpStatus.ok),
        '/manifest.json.sig' => http.Response(
            base64Encode(signature.bytes),
            HttpStatus.ok,
          ),
        '/dictionary.sqlite' =>
          http.Response.bytes(databaseBytes, HttpStatus.ok),
        _ => http.Response('', HttpStatus.notFound),
      };
    });
    final updater = PackUpdateService(
      repository: repository,
      publicKeyBase64: base64Encode(publicKey.bytes),
      client: client,
    );
    try {
      final activated = await updater.install(
        Uri.parse('http://127.0.0.1/manifest.json'),
      );
      expect(activated.version, 'test-2');
      expect(
        (await repository.search('雲')).map((item) => item.headword),
        contains('cloud'),
      );
    } finally {
      updater.dispose();
      repository.dispose();
      await temporary.delete(recursive: true);
    }
  });
}

final List<Map<String, Object?>> _minimalEntries = <Map<String, Object?>>[
  <String, Object?>{
    'headword': 'test',
    'source': 'Test',
    'source_url': 'https://example.invalid',
    'license': 'CC0-1.0',
    'attribution': 'Test',
    'senses': <Object?>[
      <String, Object?>{
        'pos': 'noun',
        'definition': 'A test.',
        'translation_zh': '測試',
      },
    ],
  },
];
