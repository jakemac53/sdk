// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:linter/src/analyzer.dart';
import 'package:linter/src/ast.dart';
import 'package:yaml/yaml.dart';

const _desc = r'Avoid using web-only libraries outside Flutter web projects.';

const _details = r'''Avoid using web libraries, `dart:html`, `dart:js` and 
`dart:js_util` in non-web Flutter projects.  These libraries are not supported
outside a web context and functionality that depends on them will fail at
runtime.

Web library access is allowed in:

* projects meant to run on the web (e.g., have a `web/` directory)
* plugin packages that declare `web` as a supported context

otherwise, imports of `dart:html`, `dart:js` and  `dart:js_util` are flagged.
''';

const _webLibs = [
  'dart:html',
  'dart:js',
  'dart:js_util',
];

/// todo (pq): consider making a utility and sharing w/ `prefer_relative_imports`
YamlMap _parseYaml(String content) {
  try {
    final doc = loadYamlNode(content);
    if (doc is YamlMap) {
      return doc;
    }
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    // Fall-through.
  }
  return YamlMap();
}

class AvoidWebLibrariesInFlutter extends LintRule implements NodeLintRule {
  AvoidWebLibrariesInFlutter()
      : super(
            name: 'avoid_web_libraries_in_flutter',
            description: _desc,
            details: _details,
            maturity: Maturity.experimental,
            group: Group.errors);

  @override
  void registerNodeProcessors(
      NodeLintRegistry registry, LinterContext context) {
    final visitor = _Visitor(this);
    registry.addCompilationUnit(this, visitor);
    registry.addImportDirective(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  File pubspecFile;

  final rule;
  _Visitor(this.rule);

  @override
  void visitCompilationUnit(CompilationUnit node) {
    pubspecFile = locatePubspecFile(node);
  }

  bool checkForValidation() {
    if (pubspecFile == null) {
      return false;
    }

    var parsedPubspec;
    try {
      final content = pubspecFile.readAsStringSync();
      parsedPubspec = _parseYaml(content);
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return false;
    }

    // Check for Flutter.
    if ((parsedPubspec['dependencies'] ?? const {})['flutter'] == null) {
      return false;
    }

    // Check for a web directory or a web plugin context declaration.
    return !pubspecFile.parent.getChild('web').exists &&
        ((parsedPubspec['flutter'] ?? const {})['plugin'] ?? const {})['web'] ==
            null;
  }

  bool _shouldValidateUri;

  bool get shouldValidateUri => _shouldValidateUri ??= checkForValidation();

  @override
  void visitImportDirective(ImportDirective node) {
    if (_webLibs.contains(node.uri.stringValue) && shouldValidateUri) {
      rule.reportLint(node);
    }
  }
}
