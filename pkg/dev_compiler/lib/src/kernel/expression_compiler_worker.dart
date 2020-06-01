// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart';
import 'package:_fe_analyzer_shared/src/messages/severity.dart';
import 'package:front_end/src/api_prototype/compiler_options.dart';
import 'package:front_end/src/api_prototype/experimental_flags.dart';
import 'package:front_end/src/api_prototype/file_system.dart';
import 'package:front_end/src/api_unstable/ddc.dart';
import 'package:kernel/ast.dart' show Component, Library;
import 'package:kernel/target/targets.dart' show TargetFlags;
import 'package:meta/meta.dart';

import '../compiler/shared_command.dart';
import 'compiler.dart';
import 'expression_compiler.dart';
import 'target.dart';

/// Listens to an input stream of compile expression requests and outputs
/// responses.
class ExpressionCompilerWorker {
  /// Additional args supplied on startup, these will be globally applied to
  /// all compile requests.
  final Stream<Map<String, dynamic>> requestStream;
  final void Function(Map<String, dynamic>) sendResponse;

  final IncrementalCompiler _incrementalCompiler;
  final _componentForUri = <Uri, Component>{};
  final _componentModuleNames = <Component, String>{};
  final _componentForLibrary = <Library, Component>{};

  ExpressionCompilerWorker._(
      this._incrementalCompiler, this.requestStream, this.sendResponse);

  static Future<void> run({
    @required Uri sdkRoot,
    @required Uri sdkSummary,
    @required Uri packagesFile,
    @required Uri librariesSpecificationUri,
    @required FileSystem fileSystem,
    Map<String, String> environmentDefines = const {},
    Map<ExperimentalFlag, bool> experiments = const {},
    SendPort sendPort,
    bool trackWidgetCreation = false,
    bool verbose = false,
  }) async {
    var options = CompilerOptions()
      ..compileSdk = false
      ..sdkRoot = sdkRoot
      ..sdkSummary = sdkSummary
      ..packagesFileUri = packagesFile
      ..librariesSpecificationUri = librariesSpecificationUri
      ..target = DevCompilerTarget(
          TargetFlags(trackWidgetCreation: trackWidgetCreation))
      ..fileSystem = fileSystem
      ..omitPlatform = true
      ..environmentDefines = environmentDefines
      ..experimentalFlags = experiments
      ..verbose = verbose;

    var processedOpts = ProcessedOptions(options: options);
    var incrementalCompiler =
        IncrementalCompiler(CompilerContext(processedOpts));
    Stream<Map<String, dynamic>> requestStream;
    void Function(Map<String, dynamic>) sendResponse;
    if (sendPort == null) {
      requestStream = stdin
          .transform(utf8.decoder.fuse(json.decoder))
          .cast<Map<String, dynamic>>();
      sendResponse = (Map<String, dynamic> response) =>
          stdout.writeln(json.encode(response));
    } else {
      var recievePort = ReceivePort();
      sendPort.send(recievePort);
      requestStream = recievePort.cast<Map<String, dynamic>>();
      sendResponse = sendPort.send;
    }
    var worker = ExpressionCompilerWorker._(
        incrementalCompiler, requestStream, sendResponse);
    await worker._start();
  }

  /// Starts listening and responding to commands.
  Future<void> _start() async {
    await for (var request in requestStream) {
      try {
        var command = request['command'] as String;
        switch (command) {
          case 'UpdateDeps':
            await _updateDeps(request);
            break;
          case 'CompileExpression':
            await _compileExpression(request);
            break;
          default:
            throw ArgumentError(
                'Unrecognized command `$command`, full request was `$request`');
        }
      } catch (e, s) {
        sendResponse({
          'exception': '$e',
          'stackTrace': '$s',
        });
      }
    }
  }

  /// Handles a `CompileExpression` request.
  Future<void> _compileExpression(Map<String, dynamic> request) async {
    var expression = request['expression'] as String;
    var libraryUri = request['libraryUri'] as String;
    var verbose = request['verbose'] as bool ?? false;
    var line = request['line'] as int;
    var column = request['column'] as int;
    var jsModules = Map<String, String>.from(request['jsModules'] as Map);
    var jsScope = Map<String, String>.from(request['jsScope'] as Map);

    var errors = <String>[];
    var warnings = <String>[];

    var component = _componentForUri[libraryUri];
    if (component == null) {
      throw ArgumentError(
          'Unable to find library `$libraryUri`, it must be loaded first.');
    }

    var moduleName = _componentModuleNames[component];
    var compiler = ProgramCompiler(
      component,
      _incrementalCompiler.getClassHierarchy(),
      SharedCompilerOptions(
          sourceMap: true, summarizeApi: false, moduleName: moduleName),
      _componentForLibrary,
      _componentModuleNames,
      coreTypes: _incrementalCompiler.getCoreTypes(),
    );

    var evaluator = ExpressionCompiler(
        _incrementalCompiler, compiler, component,
        verbose: verbose, onDiagnostic: _onDiagnosticHandler(errors, warnings));

    var compiledProcedure = await evaluator.compileExpressionToJs(
        libraryUri, line, column, jsModules, jsScope, moduleName, expression);
    sendResponse({
      'errors': errors,
      'warnings': warnings,
      'compiledProcedure': compiledProcedure,
    });
  }

  Future<void> _updateDeps(Map<String, dynamic> request) async =>
      throw UnimplementedError();
}

void Function(DiagnosticMessage) _onDiagnosticHandler(
        List<String> errors, List<String> warnings) =>
    (DiagnosticMessage message) {
      switch (message.severity) {
        case Severity.error:
        case Severity.internalProblem:
          errors.add(message.plainTextFormatted.join('\n'));
          break;
        case Severity.warning:
          warnings.add(message.plainTextFormatted.join('\n'));
          break;
        case Severity.context:
        case Severity.ignored:
          throw 'Unexpected severity: ${message.severity}';
      }
    };
