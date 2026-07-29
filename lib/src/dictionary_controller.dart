import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dictionary_repository.dart';
import 'models.dart';
import 'pack_update_service.dart';
import 'speech_service.dart';

class DictionaryController extends ChangeNotifier {
  DictionaryController({
    required this.repository,
    required this.speech,
    this.packManifestUrl = const String.fromEnvironment(
      'MYDUO_PACK_MANIFEST_URL',
    ),
    this.packPublicKey = const String.fromEnvironment(
      'MYDUO_PACK_PUBLIC_KEY',
    ),
  });

  final DictionaryRepository repository;
  final SpeechService speech;
  final String packManifestUrl;
  final String packPublicKey;

  bool initialized = false;
  bool busy = false;
  String query = '';
  String? error;
  String? statusMessage;
  List<SearchResult> results = const <SearchResult>[];
  DictionaryEntry? selected;
  List<DictionaryEntry> favoriteEntries = const <DictionaryEntry>[];
  List<HistoryRecord> historyRecords = const <HistoryRecord>[];
  int _searchGeneration = 0;

  PackInfo get activePack => repository.activePack;
  bool get canUpdate =>
      packManifestUrl.trim().isNotEmpty && packPublicKey.trim().isNotEmpty;

  Future<void> initialize() async {
    busy = true;
    notifyListeners();
    try {
      results = await repository.search('');
      favoriteEntries = await repository.favorites();
      historyRecords = await repository.history();
      initialized = true;
    } catch (exception) {
      error = exception.toString();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> search(String value) async {
    query = value;
    final generation = ++_searchGeneration;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final next = await repository.search(value);
      if (generation != _searchGeneration) {
        return;
      }
      results = next;
      if (selected != null && next.every((item) => item.id != selected!.id)) {
        selected = null;
      }
    } catch (exception) {
      if (generation == _searchGeneration) {
        error = exception.toString();
      }
    } finally {
      if (generation == _searchGeneration) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> selectResult(SearchResult result) async {
    await selectEntry(result.id, historyQuery: query);
  }

  Future<void> selectEntry(int id, {String? historyQuery}) async {
    error = null;
    try {
      final entry = await repository.entryById(id);
      if (entry == null) {
        return;
      }
      selected = entry;
      await repository.recordHistory(entry, historyQuery ?? entry.headword);
      historyRecords = await repository.history();
      notifyListeners();
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
    }
  }

  void clearSelection() {
    selected = null;
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> toggleFavorite() async {
    final entry = selected;
    if (entry == null) {
      return;
    }
    final favorite = await repository.toggleFavorite(entry);
    selected = entry.copyWith(isFavorite: favorite);
    favoriteEntries = await repository.favorites();
    statusMessage = favorite ? '已加入收藏' : '已移除收藏';
    notifyListeners();
  }

  Future<void> pronounce(EnglishAccent accent) async {
    final entry = selected;
    if (entry == null) {
      return;
    }
    error = null;
    try {
      final outcome = await speech.pronounce(
        entry,
        accent,
        audioDirectory: await repository.audioDirectoryFor(accent.name),
      );
      statusMessage = outcome == SpeechOutcome.localAudio
          ? '播放離線${accent == EnglishAccent.uk ? '英' : '美'}音'
          : '音檔缺失，已使用離線 TTS';
    } catch (exception) {
      error = exception.toString();
    }
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await repository.clearHistory();
    historyRecords = const <HistoryRecord>[];
    notifyListeners();
  }

  Future<void> refreshCollections() async {
    favoriteEntries = await repository.favorites();
    historyRecords = await repository.history();
    notifyListeners();
  }

  Future<void> installConfiguredUpdate() async {
    if (!canUpdate) {
      error = '未設定已簽章資料包來源或 Ed25519 公鑰。';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    statusMessage = '正在驗證並安裝資料包…';
    notifyListeners();
    final updater = PackUpdateService(
      repository: repository,
      publicKeyBase64: packPublicKey,
    );
    try {
      final pack = await updater.install(Uri.parse(packManifestUrl));
      results = await repository.search(query);
      selected = null;
      await refreshCollections();
      statusMessage = '資料包 ${pack.version} 已原子啟用';
    } catch (exception) {
      error = '更新失敗，已保留舊資料包：$exception';
    } finally {
      updater.dispose();
      busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, Object?>> runSmokeTest() async {
    final checks = <String, Object?>{};
    try {
      final matches = await repository.search('apple');
      checks['offline_query'] = matches.any((item) => item.headword == 'apple');
      final entry = await repository.entryByHeadword('apple');
      if (entry == null) {
        throw StateError('Starter entry apple missing.');
      }
      if (!entry.isFavorite) {
        await repository.toggleFavorite(entry);
      }
      checks['favorite'] = (await repository.favorites())
          .any((item) => item.headword == 'apple');
      await repository.recordHistory(entry, 'apple');
      checks['history'] =
          (await repository.history()).any((item) => item.headword == 'apple');
      checks['fts5'] = (await repository.search('diction'))
          .any((item) => item.headword == 'dictionary');
      checks['tts_fallback'] =
          await speech.speakText('offline dictionary', locale: 'en-US');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await speech.stop();
      checks['success'] =
          checks.values.whereType<bool>().every((value) => value);
    } catch (exception, stackTrace) {
      checks['success'] = false;
      checks['error'] = exception.toString();
      if (kDebugMode) {
        checks['stack'] = stackTrace.toString();
      }
    }
    return checks;
  }

  @override
  void dispose() {
    speech.stop();
    repository.dispose();
    super.dispose();
  }
}

Future<File> writeSmokeResult(
  String path,
  Map<String, Object?> result,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(result),
    flush: true,
  );
  return file;
}
