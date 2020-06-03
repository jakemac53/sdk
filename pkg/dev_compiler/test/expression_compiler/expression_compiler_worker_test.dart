// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:front_end/src/api_prototype/standard_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:pedantic/pedantic.dart';
import 'package:test/test.dart';

import 'package:dev_compiler/src/kernel/expression_compiler_worker.dart';

void main() async {
  final asyncHelperDillPath = p.join(p.dirname(p.dirname(p.current)),
      'out/DebugX64/gen/utils/dartdevc/pkg_kernel/async_helper.dill');
  ExpressionCompilerWorker worker;
  Future workerDone;
  StreamController<Map<String, dynamic>> requestController;
  StreamController<Map<String, dynamic>> responseController;

  setUp(() async {
    requestController = StreamController<Map<String, dynamic>>();
    responseController = StreamController<Map<String, dynamic>>();
    worker = await ExpressionCompilerWorker.create(
      librariesSpecificationUri:
          Uri.file(p.join(_sdkRoot, 'lib', 'libraries.json')),
      packagesFile: await Isolate.packageConfig,
      sdkSummary:
          Uri.file(p.join(_sdkRoot, 'lib', '_internal', 'ddc_sdk.dill')),
      fileSystem: StandardFileSystem.instance,
      requestStream: requestController.stream,
      sendResponse: responseController.add,
    );
    workerDone = worker.start();
  });

  tearDown(() async {
    unawaited(requestController.close());
    await workerDone;
    unawaited(responseController.close());
  });

  test('can load dependencies and compile expressions', () async {
    requestController.add({
      'command': 'UpdateDeps',
      'inputs': [
        {
          'path': asyncHelperDillPath,
          'moduleName': 'packages/async_helper/async_helper',
        }
      ]
    });

    requestController.add({
      'command': 'CompileExpression',
      'expression': '1 + 2',
      'line': 34,
      'column': 1,
      'jsModules': {},
      'jsScope': {},
      'libraryUri': 'package:async_helper/async_helper.dart',
      'moduleName': 'packages/async_helper/async_helper',
    });

    expect(
        responseController.stream,
        emitsInOrder([
          equals({
            'succeeded': true,
          }),
          equals({
            'succeeded': true,
            'errors': isEmpty,
            'warnings': isEmpty,
            'compiledProcedure': contains('return 1 + 2;'),
          })
        ]));
  });
}

final _sdkRoot = p.dirname(p.dirname(Platform.resolvedExecutable));
