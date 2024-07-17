#!/usr/bin/env python3
# Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Invoke the `tools/generate_package_config.dart` script.

import os
import os.path
import platform
import subprocess
import sys

USE_PYTHON3 = True


def is_windows():
    os_id = platform.system()
    return os_id == 'Windows'


def checked_in_sdk_path():
    tools_dir = os.path.dirname(os.path.realpath(__file__))
    return os.path.join(tools_dir, 'sdks', 'dart-sdk')


def checked_in_sdk_executable():
    name = 'dart'
    if is_windows():
        name = 'dart.exe'
    return os.path.join(checked_in_sdk_path(), 'bin', name)


def generate_package_config():
    sdk_dir = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    process = subprocess.run([
        checked_in_sdk_executable(),
        'pub',
        'get',
        '--offline'
    ], cwd = sdk_dir, env = {
        # Putting a fake pub hosted url enforces that we never reach out to pub.
        "PUB_HOSTED_URL": "http://fake/pub",
        # Use a custom pub cache for the SDK. Technically this should never be
        # created, but otherwise in offline mode pub might find packages a user
        # has previously downloaded.
        "PUB_CACHE": os.path.join(sdk_dir, ".dart_tool/sdk_pub_cache")
    })
    return process.returncode


def Main():
    sys.exit(generate_package_config())


if __name__ == '__main__':
    Main()
