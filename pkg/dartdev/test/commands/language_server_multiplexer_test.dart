// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../utils.dart' as utils;

void main() {
  utils.ensureRunFromSdkBinDart();

  group(
    'language-server-multiplexer',
    () {
      late utils.TestProject project;
      Process? serverProcess;
      Process? clientProcess;

      setUp(() {
        project = utils.project();
      });

      tearDown(() async {
        clientProcess?.kill();
        serverProcess?.kill();
        await clientProcess?.exitCode;
        await serverProcess?.exitCode;
      });

      test('starts multiplexer and connects client', () async {
        final testHome = path.join(project.dir.path, 'test_home');
        Directory(testHome).createSync();

        // Start multiplexer server
        serverProcess = await Process.start(
          Platform.resolvedExecutable,
          ['language-server', '--multiplexer'],
          environment: {'HOME': testHome, 'XDG_CONFIG_HOME': testHome},
        );

        // Wait for server to be ready (listening on port)
        final serverStderr = serverProcess!.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        
        final listeningLine = await serverStderr.firstWhere((line) {
          print('server stderr: $line');
          return line.contains('Multiplexer listening on port');
        }).timeout(const Duration(seconds: 10), onTimeout: () => 'Timeout');

        expect(listeningLine, contains('Multiplexer listening on port'));

        // Start client
        clientProcess = await Process.start(
          Platform.resolvedExecutable,
          ['language-server'],
          environment: {'HOME': testHome, 'XDG_CONFIG_HOME': testHome},
        );

        // Send LSP init to client
        final String message = jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'processId': pid,
            'clientInfo': {'name': 'dart-cli-tester'},
            'capabilities': {},
            'rootUri': project.dir.uri.toString(),
          },
        });

        clientProcess!.stdin.write('Content-Length: ${message.length}\r\n');
        clientProcess!.stdin.write('\r\n');
        clientProcess!.stdin.write(message);

        // Expect response
        final response = await _readLspMessage(clientProcess!.stdout);
        final json = jsonDecode(response);
        expect(json['id'], 1);
        expect(json['result'], isNotNull);
      });
    },
    timeout: utils.longTimeout,
  );
}

/// Reads the first LSP message from [stream].
Future<String> _readLspMessage(Stream<List<int>> stream) {
  const lspHeaderBodySeparator = '\r\n\r\n';
  final contentLengthRegExp = RegExp(r'Content-Length: (\d+)\r\n');

  final completer = Completer<String>();
  final buffer = StringBuffer();
  late final StreamSubscription<String> inSubscription;
  inSubscription = stream.transform<String>(utf8.decoder).listen((data) {
    buffer.write(data);
    final bufferString = buffer.toString();

    if (bufferString.contains(lspHeaderBodySeparator)) {
      final parts = bufferString.split(lspHeaderBodySeparator);
      final headers = parts[0];
      final body = parts[1];
      final length = int.parse(
        contentLengthRegExp.firstMatch(headers)![1]!);
      if (body.length >= length) {
        completer.complete(body.substring(0, length));
        inSubscription.cancel();
      }
    }
  });

  return completer.future;
}
