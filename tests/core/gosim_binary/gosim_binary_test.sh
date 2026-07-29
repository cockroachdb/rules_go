#!/bin/sh
set -eu

output="$(${TEST_SRCDIR}/${TEST_WORKSPACE}/tests/core/gosim_binary/hello_gosim)"
test "${output}" = "hello"
