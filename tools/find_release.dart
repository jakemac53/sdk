// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A tool to find the earliest Dart and Flutter release containing a given
/// commit.
///
/// Usage:
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

final parser = ArgParser()
  ..addOption(
    'commit',
    abbr: 'c',
    help: 'The commit to search for',
    mandatory: true,
  )
  ..addOption(
    'channel',
    help: 'The channel to search for the commit in, dev only supports the dart '
        'sdk since flutter does not do dev releases.',
    allowed: ['dev', 'stable', 'beta'],
    mandatory: true,
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show usage information',
  );

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    arguments = [
      '--commit',
      '0a95e6f14952e45abe19265d3fb67634ee50f9e2',
      '--channel',
      'beta',
    ];
  }
  try {
    final parsedArgs = parser.parse(arguments);
    if (parsedArgs['help'] as bool) {
      print(parser.usage);
      exit(0);
    }
    final commit = parsedArgs['commit'] as String;
    final channel = parsedArgs['channel'] as String;
    print('Searching for commit $commit in channel $channel');

    final repo = await findRepoForCommit(commit);
    if (repo == null) {
      print('Commit not found in Dart or Flutter repositories.');
      exit(1);
    }
    print('Found commit in $repo');

    print('Fetching earliest release tag for $commit...');
    final tag = await fetchOldestVersionTag(repo, commit, channel);
    if (tag == null) {
      print('No release tags found for commit $commit in $repo');
      exit(1);
    }
    print('Earliest release tag for $commit was: $tag');

    if (repo == flutterSdkRepo || (channel == 'beta' || channel == 'stable')) {
      print('Checking for earliest flutter release newer than $tag...');
      final flutterRelease = await fetchEarliestFlutterRelease(
        repo,
        channel,
        tag,
      );
      if (flutterRelease == null) {
        print(
          'No Flutter releases found '
          '${repo == dartSdkRepo ? 'with a Dart sdk ' : ''}'
          'newer than $tag',
        );
      } else {
        print('Earliest Flutter release: $flutterRelease');
      }
    } else {
      print(
        'Skipping flutter version check for channel $channel, only `beta` and '
        '`stable` are supported for flutter version checks',
      );
    }

    if (repo == dartSdkRepo) {
      print('Checking for earliest Dart release newer than $tag...');
      final dartRelease = await fetchEarliestDartReleaseFromGcs(
        'channels/$channel/release/',
        tag,
      );
      if (dartRelease == null) {
        print('No Dart releases found that were newer than $tag');
      } else {
        print('Earliest Dart release: $dartRelease');
      }
    } else {
      print('Skipping dart version check as this was a flutter commit');
    }
  } on FormatException catch (e) {
    print(e.message);
    print(parser.usage);
    exit(1);
  }
}

const dartSdkRepo = 'dart-lang/sdk';
const flutterSdkRepo = 'flutter/flutter';

Future<String?> findRepoForCommit(String sha) async {
  if (await checkCommit(dartSdkRepo, sha)) return dartSdkRepo;
  if (await checkCommit(flutterSdkRepo, sha)) return flutterSdkRepo;
  return null;
}

Future<bool> checkCommit(String repo, String sha) async {
  try {
    await makeGhApiRequest('repos/$repo/commits/$sha');
    return true;
  } on RequestException catch (_) {
    return false;
  }
}

Future<Version?> fetchOldestVersionTag(
  String repo,
  String commit,
  String channel,
) async {
  final response = await makeGhApiRequest(
    '$repo/branch_commits/$commit.json',
    isApiRequest: false,
  );
  final tags = (response['tags'] as List).cast<String>();
  Version? oldest;
  for (final tag in tags) {
    try {
      final version = Version.parse(tag);
      if (oldest == null || version < oldest) {
        oldest = version;
      }
    } on FormatException catch (_) {
      continue;
    }
  }
  return oldest;
}

Future<Map<String, Object?>> makeGhApiRequest(
  String path, {
  bool isApiRequest = true,
}) async {
  var uri = Uri.parse(
    isApiRequest ? 'https://api.github.com/$path' : 'https://github.com/$path',
  );
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw RequestException(response, uri);
  }
  return jsonDecode(response.body) as Map<String, Object?>;
}

Future<Version?> fetchEarliestDartReleaseFromGcs(
  String prefix,
  Version minVersion,
) async {
  final uri = Uri.parse(
    'https://storage.googleapis.com/storage/v1/b/dart-archive/o?delimiter=/&prefix=$prefix&alt=json',
  );
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw RequestException(response, uri);
  }
  Version? earliest;
  try {
    final releases = ((jsonDecode(response.body)
            as Map<String, Object?>)['prefixes'] as List)
        .cast<String>();
    for (var release in releases) {
      final versionPart = release.split('/')[3];
      try {
        final version = Version.parse(versionPart);
        if (version >= minVersion && (earliest == null || version < earliest)) {
          earliest = version;
        }
      } on FormatException catch (_) {
        continue;
      }
    }
  } catch (e) {
    throw RequestException(response, uri);
  }
  return earliest;
}

Future<Version?> fetchEarliestFlutterRelease(
  String repo, // The repo that `minVersion` corresponds to.
  String channel,
  Version minVersion,
) async {
  final uri = Uri.parse(
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json',
  );
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw RequestException(response, uri);
  }
  Version? earliest;
  try {
    final releases = ((jsonDecode(response.body)
            as Map<String, Object?>)['releases'] as List)
        .cast<Map<String, Object?>>();
    for (var release in releases) {
      // We do search for dart releases in any flutter channel because sometimes
      // stable flutter releases contain dart sdk releases from beta channels.
      if (repo == flutterSdkRepo && release['channel'] != channel) continue;

      var versionStr = switch (repo) {
        dartSdkRepo => release['dart_sdk_version'] as String?,
        flutterSdkRepo => release['version'] as String,
        _ => throw FormatException('Unknown repository $repo'),
      };
      if (versionStr == null) continue;
      // Some versions look like `3.11.0 (build 3.11.0-93.1.beta)`
      if (versionStr.contains('(build')) {
        versionStr = versionStr.split('(build ').last;
        versionStr = versionStr.substring(0, versionStr.length - 1);
      }

      try {
        final version = Version.parse(versionStr);
        if (version >= minVersion && (earliest == null || version < earliest)) {
          earliest = version;
        }
      } on FormatException catch (_) {
        continue;
      }
    }
  } catch (e) {
    throw RequestException(response, uri, e);
  }
  return earliest;
}

class RequestException implements Exception {
  final http.Response response;
  final Uri uri;
  final Object? error;

  RequestException(this.response, this.uri, [this.error]);

  @override
  String toString() => '''
uri: $uri
statusCode:  ${response.statusCode}
body: ${response.body}
error: $error
''';
}
