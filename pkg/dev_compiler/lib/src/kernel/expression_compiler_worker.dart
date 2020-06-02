// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:build_integration/file_system/multi_root.dart';
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
import 'command.dart';
import 'compiler.dart';
import 'expression_compiler.dart';
import 'target.dart';

/// Listens to an input stream of compile expression requests and outputs
/// responses.
class ExpressionCompilerWorker {
  final Stream<Map<String, dynamic>> requestStream;
  final void Function(Map<String, dynamic>) sendResponse;

  final _componentForLibrary = <Library, Component>{};
  final _componentForLibraryUri = <String, Component>{};
  final _componentModuleNames = <Component, String>{};
  final ProcessedOptions _processedOptions;
  final Component _sdkComponent;

  ExpressionCompilerWorker._(this._processedOptions, this._sdkComponent,
      this.requestStream, this.sendResponse);

  static Future<void> runFromArgs(List<String> args, {SendPort sendPort}) {
    // We are destructive on `args`, so make a copy.
    args = args.toList();
    var environmentDefines = parseAndRemoveDeclaredVariables(args);
    var parsedArgs = argParser.parse(args);
    FileSystem fileSystem = StandardFileSystem.instance;
    var multiRoots = parsedArgs['multi-root'] as List<String>;
    if (multiRoots.isNotEmpty) {
      fileSystem = MultiRootFileSystem(
          parsedArgs['multi-root-scheme'] as String, multiRoots, fileSystem);
    }
    var experimentalFlags = parseExperimentalFlags(
        parseExperimentalArguments(
            parsedArgs['enable-experiment'] as List<String>),
        onError: (e) => throw e);
    return run(
      librariesSpecificationUri:
          _argToUri(parsedArgs['libraries-file'] as String),
      packagesFile: _argToUri(parsedArgs['packages-file'] as String),
      sdkSummary: _argToUri(parsedArgs['dart-sdk-summary'] as String),
      fileSystem: fileSystem,
      environmentDefines: environmentDefines,
      experimentalFlags: experimentalFlags,
      sdkRoot: _argToUri(parsedArgs['sdk-root'] as String),
      sendPort: sendPort,
      trackWidgetCreation: parsedArgs['track-widget-creation'] as bool,
      verbose: parsedArgs['verbose'] as bool,
    );
  }

  static Future<void> run({
    @required Uri librariesSpecificationUri,
    @required Uri packagesFile,
    @required Uri sdkSummary,
    @required FileSystem fileSystem,
    Map<String, String> environmentDefines = const {},
    Map<ExperimentalFlag, bool> experimentalFlags = const {},
    Uri sdkRoot,
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
      ..experimentalFlags = experimentalFlags
      ..verbose = verbose;

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
    var processedOpts = ProcessedOptions(options: options);
    var sdkComponent = await processedOpts.loadSdkSummary(null);
    var worker = ExpressionCompilerWorker._(
        processedOpts, sdkComponent, requestStream, sendResponse);
    await worker._start();
  }

  /// Starts listening and responding to commands.
  Future<void> _start() async {
    await for (var request in requestStream) {
      try {
        var command = request['command'] as String;
        switch (command) {
          case 'UpdateDeps':
            sendResponse(
                await _updateDeps(UpdateDepsRequest.fromJson(request)));
            break;
          case 'CompileExpression':
            sendResponse(await _compileExpression(
                CompileExpressionRequest.fromJson(request)));
            break;
          default:
            throw ArgumentError(
                'Unrecognized command `$command`, full request was `$request`');
        }
      } catch (e, s) {
        sendResponse({
          'exception': '$e',
          'stackTrace': '$s',
          'succeeded': false,
        });
      }
    }
  }

  /// Handles a `CompileExpression` request.
  Future<Map<String, dynamic>> _compileExpression(
      CompileExpressionRequest request) async {
    var errors = <String>[];
    var warnings = <String>[];

    var component = _componentForLibraryUri[request.libraryUri];
    if (component == null) {
      throw ArgumentError(
          'Unable to find library `${request.libraryUri}`, it must be loaded first.');
    }

    var moduleName = _componentModuleNames[component];
    var incrementalCompiler = IncrementalCompiler.forExpressionCompilationOnly(
        CompilerContext(_processedOptions), component);
    var compiler = ProgramCompiler(
      component,
      incrementalCompiler.getClassHierarchy(),
      SharedCompilerOptions(
          sourceMap: true, summarizeApi: false, moduleName: moduleName),
      _componentForLibrary,
      _componentModuleNames,
      coreTypes: incrementalCompiler.getCoreTypes(),
    );

    var evaluator = ExpressionCompiler(incrementalCompiler, compiler, component,
        verbose: _processedOptions.verbose,
        onDiagnostic: _onDiagnosticHandler(errors, warnings));

    var compiledProcedure = await evaluator.compileExpressionToJs(
        request.libraryUri,
        request.line,
        request.column,
        request.jsModules,
        request.jsScope,
        moduleName,
        request.expression);
    return {
      'errors': errors,
      'warnings': warnings,
      'compiledProcedure': compiledProcedure,
      'succeeded': errors.isEmpty,
    };
  }

  /// Loads in the specified dill files and invalidates any existing ones.
  Future<Map<String, dynamic>> _updateDeps(UpdateDepsRequest request) async {
    for (var input in request.inputs) {
      var bytes = await File(input.path).readAsBytes();
      var component = await _processedOptions.loadComponent(
          bytes, _sdkComponent.root,
          alwaysCreateNewNamedNodes: true);
      _componentModuleNames[component] = input.moduleName;
      for (var lib in component.libraries) {
        _componentForLibrary[lib] = component;
        _componentForLibraryUri[lib.importUri.toString()] = component;
      }
    }
    return {'succeeded': true};
  }
}

class CompileExpressionRequest {
  final int column;
  final String expression;
  final Map<String, String> jsModules;
  final Map<String, String> jsScope;
  final String libraryUri;
  final int line;

  CompileExpressionRequest({
    @required this.expression,
    @required this.column,
    @required this.jsModules,
    @required this.jsScope,
    @required this.libraryUri,
    @required this.line,
  });

  factory CompileExpressionRequest.fromJson(Map<String, dynamic> json) =>
      CompileExpressionRequest(
        expression: json['expression'] as String,
        line: json['line'] as int,
        column: json['column'] as int,
        jsModules: Map<String, String>.from(json['jsModules'] as Map),
        jsScope: Map<String, String>.from(json['jsScope'] as Map),
        libraryUri: json['libraryUri'] as String,
      );
}

class UpdateDepsRequest {
  final List<InputDill> inputs;

  UpdateDepsRequest(this.inputs);

  factory UpdateDepsRequest.fromJson(Map<String, dynamic> json) =>
      UpdateDepsRequest([
        for (var input in json['inputs'] as List)
          InputDill(input['path'] as String, input['moduleName'] as String),
      ]);
}

class InputDill {
  final String moduleName;
  final String path;

  InputDill(this.path, this.moduleName);
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

final argParser = ArgParser()
  ..addOption('dart-sdk-summary')
  ..addMultiOption('enable-experiment',
      help: 'Enable a language experiment when invoking the CFE.')
  ..addOption('libraries-file')
  ..addMultiOption('multi-root')
  ..addOption('multi-root-scheme', defaultsTo: 'org-dartlang-app')
  ..addOption('packages-file')
  ..addOption('sdk-root')
  ..addFlag('track-widget-creation', defaultsTo: false)
  ..addFlag('verbose', defaultsTo: false);

Uri _argToUri(String uriArg) =>
    uriArg == null ? null : Uri.base.resolve(uriArg.replaceAll('\\', '/'));
