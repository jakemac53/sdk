// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.json_decode_experimental;

import '../core_types.dart';
import '../ast.dart';

final _jsonAutoDecodeUri =
    Uri(scheme: 'package', path: 'json_auto_decode/json_auto_decode.dart');

class JsonDecodeExperimentalTransformer extends Transformer {
  final CoreTypes coreTypes;
  final InterfaceType iterableDynamic;
  final Library library;
  final InterfaceType mapStringDynamic;
  final Class mapEntryClass;

  /// Nullable, indicates we can skip the transformation if null.
  final Library jsonAutoDecodeLib;

  /// We add procedures to the library and they are shared across static
  /// invocations within that library.
  final deserializers = <DartType, Procedure>{};

  /// The current static invocation we are visiting.
  StaticInvocation _current;

  JsonDecodeExperimentalTransformer(this.coreTypes, this.library)
      : iterableDynamic =
            InterfaceType(coreTypes.iterableClass, const [DynamicType()]),
        mapStringDynamic = InterfaceType(coreTypes.mapClass,
            [coreTypes.stringClass.thisType, DynamicType()]),
        mapEntryClass = coreTypes.index.getClass('dart:core', 'MapEntry'),
        jsonAutoDecodeLib = library.dependencies
            .firstWhere(
                (l) =>
                    l.isImport &&
                    l.targetLibrary.importUri == _jsonAutoDecodeUri,
                orElse: () => null)
            ?.targetLibrary;

  @override
  Expression visitStaticInvocation(StaticInvocation node) {
    // No dependency on this package, just return early.
    if (jsonAutoDecodeLib == null) return node;

    _current = node;
    node.transformChildren(this);
    final procedure = node.target;
    if (!procedure.isStatic) return node;
    if (procedure.enclosingLibrary.importUri == _jsonAutoDecodeUri) {
      InterfaceType typeArg;
      VariableDeclaration jsonVar;
      VariableDeclaration jsonDecoderVar;
      if (procedure.name.name == 'jsonAutoDecode') {
        // We know we have exactly one type argument.
        typeArg = node.arguments.types.first as InterfaceType;
        jsonVar = VariableDeclaration(
          'json',
          type: const DynamicType(),
          initializer: StaticInvocation(
            coreTypes.index.getTopLevelMember('dart:convert', 'jsonDecode'),
            Arguments(node.arguments.positional),
          ),
        );
      } else if (procedure.name.name == 'jsonAutoDecodeFromBytes') {
        // We know we have exactly one type argument.
        typeArg = node.arguments.types.first as InterfaceType;
        var utf8Codec = StaticGet(
            coreTypes.index.getTopLevelMember('dart:convert', 'utf8'));
        var jsonCodec = StaticGet(
            coreTypes.index.getTopLevelMember('dart:convert', 'json'));
        jsonDecoderVar = VariableDeclaration(
          'jsonDecoder',
          initializer: MethodInvocation(
            jsonCodec,
            Name('fuse'),
            Arguments([utf8Codec]),
          ),
        );
        jsonVar = VariableDeclaration('json',
            type: const DynamicType(),
            initializer: MethodInvocation(
              VariableGet(jsonDecoderVar),
              Name('decode'),
              Arguments(node.arguments.positional),
            ));
      } else {
        return node;
      }

      var newInstanceExpr = _deserialize(typeArg, VariableGet(jsonVar));
      var expr = MethodInvocation(
          FunctionExpression(FunctionNode(
            Block([
              if (jsonDecoderVar != null) jsonDecoderVar,
              jsonVar,
              ReturnStatement(newInstanceExpr),
            ]),
            returnType: typeArg,
          )),
          Name('call'),
          Arguments.empty());
      return expr;
    }
    return node;
  }

  /// Invokes the deserializer for [type] with [argExpr].
  ///
  /// If a deserializer does not exist then a [Procedure] in the current
  /// library is created, added to [deserializers], and invoked.
  Expression _deserialize(DartType type, Expression argExpr,
      {Expression defaultValue}) {
    if (!deserializers.containsKey(type)) {
      var jsonVar = VariableDeclaration('json');
      var defaultVar = VariableDeclaration('defaultValue');
      // The function body is assigned lazily to prevent infinite
      // recursion during expansion (the _convert call here).
      var fnNode = FunctionNode(null,
          positionalParameters: [jsonVar],
          namedParameters: [defaultVar],
          returnType: type);
      var procedure = Procedure(
          Name('_\$deserializer${deserializers.length}', library),
          ProcedureKind.Method,
          fnNode,
          isStatic: true)
        // Dart2js requires a valid file offset and uri for all nodes (or one
        // of their parents). We treat these nodes as being located at the
        // offset of the static invocation that generated them.
        ..fileOffset = _current.fileOffset
        ..fileUri = _current.location.file;
      library.addProcedure(procedure);
      deserializers[type] = procedure;

      fnNode.body = ReturnStatement(
          _convert(type, VariableGet(jsonVar), VariableGet(defaultVar)))
        ..parent = fnNode;
    }

    return StaticInvocation(
        deserializers[type],
        Arguments([
          argExpr
        ], named: [
          if (defaultValue != null)
            NamedExpression('defaultValue', defaultValue)
        ]));
  }

  /// Creates an arbitrary instance of Type [type] from the dynamic json object
  /// [jsonArg] using [deserializers].
  Expression _convert(
      DartType type, VariableGet jsonArg, VariableGet defaultValueArg) {
    if (type is DynamicType) {
      return jsonArg;
    } else if (type is InterfaceType) {
      var library = type.classNode.enclosingLibrary;
      if (library.importUri.scheme != 'dart') {
        if (library.importUri == _jsonAutoDecodeUri) {
          switch (type.classNode.name) {
            case 'LazyList':
            case 'LazyMap':
              return _convertLazyCollection(type, jsonArg, defaultValueArg);
            default:
              throw UnsupportedError('Unsupported type $type');
          }
        }
        return _convertCustomType(type, jsonArg, defaultValueArg);
      } else if (library == coreTypes.coreLibrary) {
        return _convertCoreType(type, jsonArg, defaultValueArg);
      }
    }

    throw '''
Unsupported type: ${type}
''';
  }

  /// Creates a new instance of the core type [type] from the object referenced
  /// by [argExpr].
  Expression _convertCoreType(
      InterfaceType type, Expression argExpr, Expression defaultValueExpr) {
    switch (type.className.canonicalName.name) {
      case 'Object':
        return argExpr;
      case 'Null':
        return AsExpression(argExpr, type)..isTypeError = true;
      case 'String':
      case 'bool':
      case 'int':
      case 'double':
        return _nullCheckTernary(argExpr, defaultValueExpr,
            AsExpression(argExpr, type)..isTypeError = true, type);
      case 'Iterable':
      case 'List':
        // Iterable and list are treated identically other than calling a
        // different procedure.
        var decoder = jsonAutoDecodeLib.procedures.firstWhere((p) =>
            p.name.name == 'convert${type.className.canonicalName.name}');
        var valueType = type.typeArguments.first;
        var lambdaArg = VariableDeclaration('v');
        return StaticInvocation(
            decoder,
            Arguments(
              [
                argExpr,
                FunctionExpression(FunctionNode(
                    ReturnStatement(
                        _deserialize(valueType, VariableGet(lambdaArg))),
                    positionalParameters: [lambdaArg],
                    returnType: valueType))
              ],
              named: [
                if (defaultValueExpr != null)
                  NamedExpression('defaultValue', defaultValueExpr)
              ],
              types: [const DynamicType(), valueType],
            ));
      case 'Map':
        var decoder = jsonAutoDecodeLib.procedures
            .firstWhere((p) => p.name.name == 'convertMap');

        var keyType = type.typeArguments.first;
        var valueType = type.typeArguments[1];
        var kLambdaArg = VariableDeclaration('k');
        var vLambdaArg = VariableDeclaration('v');
        return StaticInvocation(
            decoder,
            Arguments(
              [
                argExpr,
                FunctionExpression(FunctionNode(
                    ReturnStatement(
                        _deserialize(keyType, VariableGet(kLambdaArg))),
                    positionalParameters: [kLambdaArg],
                    returnType: keyType)),
                FunctionExpression(FunctionNode(
                    ReturnStatement(
                        _deserialize(valueType, VariableGet(vLambdaArg))),
                    positionalParameters: [vLambdaArg],
                    returnType: valueType)),
              ],
              named: [
                if (defaultValueExpr != null)
                  NamedExpression('defaultValue', defaultValueExpr)
              ],
              types: [
                const DynamicType(),
                const DynamicType(),
                keyType,
                valueType,
              ],
            ));
      default:
        throw '''
Unsupported core type: ${type.className};
  ''';
    }
  }

  /// Creates a custom instance of [type] from the object referenced by [argExpr].
  ConditionalExpression _convertCustomType(
      InterfaceType type, Expression argExpr, Expression defaultValueExpr) {
    var clazz = type.classNode;

    var constructor = clazz.constructors
        .firstWhere((c) => c.name.name == '', orElse: () => null);
    if (constructor == null) {
      throw UnsupportedError('''
Unable to find an unnamed constructor for type:

  class: ${clazz.name}
  library: ${clazz.enclosingLibrary.importUri}

jsonAutoDecode only works for core types and types with unnamed constructors.
''');
    }

    var positionalParams = constructor.function.positionalParameters;
    var positionalArgs = [
      for (var param in positionalParams) _parameterValue(type, param, argExpr)
    ];

    var namedParams = constructor.function.namedParameters;
    var namedArgs = [
      for (var param in namedParams)
        NamedExpression(param.name, _parameterValue(type, param, argExpr))
    ];

    return _nullCheckTernary(
        argExpr,
        defaultValueExpr,
        ConstructorInvocation(
            constructor,
            Arguments(
              positionalArgs,
              named: namedArgs,
              types: type.typeArguments,
            )),
        type);
  }

  ConditionalExpression _nullCheckTernary(Expression argExpr, Expression ifNull,
          Expression ifNotNull, DartType type) =>
      ConditionalExpression(
        MethodInvocation(argExpr, Name('=='), Arguments([NullLiteral()])),
        ifNull ?? NullLiteral(),
        ifNotNull,
        type,
      );

  Expression _parameterValue(InterfaceType parent,
      VariableDeclaration methodParam, Expression argExpr) {
    // First, build the expression to get the value out of the map
    Expression mapValueExpr;

    if (argExpr is VariableGet || argExpr is MethodInvocation) {
      mapValueExpr = MethodInvocation(
        AsExpression(argExpr, mapStringDynamic)..isTypeError = true,
        Name('[]'),
        Arguments([StringLiteral(methodParam.name)]),
        mapStringDynamic.classNode.members
            .firstWhere((m) => m.name == Name('[]')),
      );
    } else {
      throw '''
  Unrecognized argument type:

    runtimeType: ${argExpr.runtimeType}
    value: $argExpr
  ''';
    }

    // Now build the actual argument expression based on the type of the argument.
    if (methodParam.type is! InterfaceType) {
      throw '''
  Unsupported type, only classes are supported: ${methodParam.type}
  ''';
    }
    var paramType = methodParam.type as InterfaceType;

    var newTypeArgs = paramType.typeArguments.map((typeArg) {
      if (typeArg is TypeParameterType) {
        var index = parent.classNode.typeParameters.indexOf(typeArg.parameter);
        return parent.typeArguments[index];
      }
      return typeArg;
    }).toList();

    paramType = InterfaceType(paramType.classNode, newTypeArgs);
    return _deserialize(paramType, mapValueExpr,
        defaultValue: methodParam.initializer);
  }

  ConditionalExpression _convertLazyCollection(
      InterfaceType type, Expression argExpr, Expression defaultValueExpr) {
    var clazz = type.classNode;
    var targetType = type.typeArguments.first;
    var vParam = VariableDeclaration('v', type: const DynamicType());
    var converter = FunctionExpression(
      FunctionNode(
          ReturnStatement(_deserialize(targetType, VariableGet(vParam))),
          returnType: targetType,
          positionalParameters: [vParam]),
    );
    return _nullCheckTernary(
        argExpr,
        defaultValueExpr,
        ConstructorInvocation(
            clazz.constructors.firstWhere((c) => c.name.name == ''),
            Arguments(
              [argExpr, converter],
              types: type.typeArguments,
            )),
        type);
  }
}
