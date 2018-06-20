#!/usr/bin/env dart
// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Command line entry point for Dart Development Compiler (dartdevc), used to
/// compile a collection of dart libraries into a single JS module

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/command_line/arguments.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisEngine;
import 'package:analyzer/src/summary/package_bundle_reader.dart'
    show SummaryDataStore;
import 'package:analyzer/src/summary/idl.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:dev_compiler/src/analyzer/command.dart';
import 'package:front_end/src/byte_store/cache.dart';

Future main(List<String> args) async {
  // Always returns a new modifiable list.
  args = preprocessArgs(PhysicalResourceProvider.INSTANCE, args);

  if (args.contains('--persistent_worker')) {
    await _CompilerWorker(args..remove('--persistent_worker')).run();
  } else if (args.isNotEmpty && args.last == "--batch") {
    await runBatch(args.sublist(0, args.length - 1));
  } else {
    exitCode = compile(args);
  }
}

/// Runs the compiler worker loop.
class _CompilerWorker extends AsyncWorkerLoop {
  /// The original args supplied to the executable.
  final List<String> _startupArgs;

  final packageBundleCache = new WorkerPackageBundleCache(
      PhysicalResourceProvider.INSTANCE, 1024 * 1024 * 1024);

  _CompilerWorker(this._startupArgs) : super();

  /// Performs each individual work request.
  Future<WorkResponse> performRequest(WorkRequest request) async {
    var args = _startupArgs.toList()..addAll(request.arguments);
    var output = StringBuffer();

    // Prepare inputs with their digests.
    Map<String, WorkerInput> inputs = {};
    for (var input in request.inputs) {
      inputs[input.path] = new WorkerInput(input.path, input.digest);
    }
    // Read the summaries.
    var summaryDataStore = new SummaryDataStore(<String>[]);
    var packageBundleProvider = new WorkerPackageBundleProvider(
        packageBundleCache, inputs, output.writeln);

    // Adds a bundle at `path` to `summaryDataStore`.
    PackageBundle addBundle(String path) {
      PackageBundle bundle = packageBundleProvider.get(path);
      summaryDataStore.addBundle(path, bundle);
      return bundle;
    }

    for (var path in inputs.keys) {
      addBundle(path);
    }

    var exitCode =
        compile(args, printFn: output.writeln, summaryData: summaryDataStore);
    AnalysisEngine.instance.clearCaches();
    return WorkResponse()
      ..exitCode = exitCode
      ..output = output.toString();
  }
}

runBatch(List<String> batchArgs) async {
  int totalTests = 0;
  int testsFailed = 0;
  var watch = Stopwatch()..start();
  print('>>> BATCH START');
  String line;
  while ((line = stdin.readLineSync(encoding: utf8)).isNotEmpty) {
    totalTests++;
    var args = batchArgs.toList()..addAll(line.split(RegExp(r'\s+')));

    // We don't try/catch here, since `compile` should handle that.
    var compileExitCode = compile(args);
    AnalysisEngine.instance.clearCaches();
    stderr.writeln('>>> EOF STDERR');
    var outcome = compileExitCode == 0
        ? 'PASS'
        : compileExitCode == 70 ? 'CRASH' : 'FAIL';
    print('>>> TEST $outcome ${watch.elapsedMilliseconds}ms');
  }
  int time = watch.elapsedMilliseconds;
  print('>>> BATCH END '
      '(${totalTests - testsFailed})/$totalTests ${time}ms');
}

/**
 * Worker input.
 *
 * Bazel does not specify the format of the digest, so we cannot assume that
 * the digest itself is enough to uniquely identify inputs. So, we use a pair
 * of path + digest.
 */
class WorkerInput {
  static const _digestEquality = const ListEquality<int>();

  final String path;
  final List<int> digest;

  WorkerInput(this.path, this.digest);

  @override
  int get hashCode => _digestEquality.hash(digest);

  @override
  bool operator ==(Object other) {
    return other is WorkerInput &&
        other.path == path &&
        _digestEquality.equals(other.digest, digest);
  }

  @override
  String toString() => '$path @ ${hex.encode(digest)}';
}

/**
 * Value object for [WorkerPackageBundleCache].
 */
class WorkerPackageBundle {
  final List<int> bytes;
  final PackageBundle bundle;

  WorkerPackageBundle(this.bytes, this.bundle);

  /**
   * Approximation of a bundle size in memory.
   */
  int get size => bytes.length * 3;
}

/**
 * Cache of [PackageBundle]s.
 */
class WorkerPackageBundleCache {
  final ResourceProvider resourceProvider;
  final Cache<WorkerInput, WorkerPackageBundle> _cache;

  WorkerPackageBundleCache(this.resourceProvider, int maxSizeBytes)
      : _cache = new Cache<WorkerInput, WorkerPackageBundle>(
            maxSizeBytes, (value) => value.size);

  /**
   * Get the [PackageBundle] from the file with the given [path] in the context
   * of the given worker [inputs].
   */
  PackageBundle get(Map<String, WorkerInput> inputs, String path,
      void Function(String) printFn) {
    WorkerInput input = inputs[path];

    // The input must be not null, otherwise we're not expected to read
    // this file, but we check anyway to be safe.
    if (input == null) {
      printFn('Unable to load $path from cache, loading from disk.');
      var bytes = resourceProvider.getFile(path).readAsBytesSync();
      return new PackageBundle.fromBuffer(bytes);
    }

    return _cache.get(input, () {
      // printFn('Loading $input from disk and caching.');
      var bytes = resourceProvider.getFile(path).readAsBytesSync();
      var bundle = new PackageBundle.fromBuffer(bytes);
      return new WorkerPackageBundle(bytes, bundle);
    }).bundle;
  }
}

/**
 * [PackageBundleProvider] that reads from [WorkerPackageBundleCache] using
 * the request specific [inputs].
 */
class WorkerPackageBundleProvider {
  final WorkerPackageBundleCache cache;
  final Map<String, WorkerInput> inputs;
  final void Function(String) printFn;

  WorkerPackageBundleProvider(this.cache, this.inputs, this.printFn);

  PackageBundle get(String path) {
    return cache.get(inputs, path, printFn);
  }
}
