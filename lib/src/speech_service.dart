import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

enum EnglishAccent { uk, us }

enum SpeechOutcome { localAudio, offlineTts }

class SpeechService {
  SpeechService({
    MethodChannel channel =
        const MethodChannel('io.github.chingfuhan.myduo/speech'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<SpeechOutcome> pronounce(
    DictionaryEntry entry,
    EnglishAccent accent, {
    required String audioDirectory,
  }) async {
    var relativeAudio =
        accent == EnglishAccent.uk ? entry.audioUk : entry.audioUs;
    if (relativeAudio.isNotEmpty) {
      final accentPrefix = '${accent.name}/';
      if (relativeAudio.replaceAll(r'\', '/').startsWith(accentPrefix)) {
        relativeAudio =
            relativeAudio.replaceAll(r'\', '/').substring(accentPrefix.length);
      }
      final absoluteAudio = p.normalize(p.join(audioDirectory, relativeAudio));
      if (p.isWithin(audioDirectory, absoluteAudio) &&
          await File(absoluteAudio).exists()) {
        final played = await _channel.invokeMethod<bool>(
              'playAudio',
              <String, Object?>{'path': absoluteAudio},
            ) ??
            false;
        if (played) {
          return SpeechOutcome.localAudio;
        }
      }
    }

    final spoken = await _channel.invokeMethod<bool>(
          'speak',
          <String, Object?>{
            'text': entry.headword,
            'locale': accent == EnglishAccent.uk ? 'en-GB' : 'en-US',
          },
        ) ??
        false;
    if (!spoken) {
      throw PlatformException(
        code: 'tts_unavailable',
        message: 'No offline speech voice is available for this accent.',
      );
    }
    return SpeechOutcome.offlineTts;
  }

  Future<bool> speakText(String text, {String locale = 'en-US'}) async {
    return await _channel.invokeMethod<bool>(
          'speak',
          <String, Object?>{'text': text, 'locale': locale},
        ) ??
        false;
  }

  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }
}
