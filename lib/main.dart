import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/dictionary_controller.dart';
import 'src/dictionary_repository.dart';
import 'src/speech_service.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = await DictionaryRepository.open();
  final controller = DictionaryController(
    repository: repository,
    speech: SpeechService(),
  );
  await controller.initialize();

  if (arguments.contains('--smoke-test')) {
    runApp(_SmokeHarness(controller: controller, arguments: arguments));
    return;
  }
  runApp(MyDuoApp(controller: controller));
}

class _SmokeHarness extends StatefulWidget {
  const _SmokeHarness({
    required this.controller,
    required this.arguments,
  });

  final DictionaryController controller;
  final List<String> arguments;

  @override
  State<_SmokeHarness> createState() => _SmokeHarnessState();
}

class _SmokeHarnessState extends State<_SmokeHarness> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final outputArgument = widget.arguments.where(
      (argument) => argument.startsWith('--smoke-output='),
    );
    final outputPath = outputArgument.isEmpty
        ? '${Directory.current.path}${Platform.pathSeparator}'
            'smoke-test-result.json'
        : outputArgument.first.substring('--smoke-output='.length);
    final result = await widget.controller.runSmokeTest();
    await writeSmokeResult(outputPath, result);
    widget.controller.dispose();
    exit(result['success'] == true ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('MyDuo offline smoke test'),
            ],
          ),
        ),
      ),
    );
  }
}
