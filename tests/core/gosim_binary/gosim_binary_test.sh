#!/bin/sh
set -eu

output="$(${TEST_SRCDIR}/${TEST_WORKSPACE}/tests/core/gosim_binary/hello_gosim)"
case "${output}" in
  "root="*"//tests/core/gosim_binary:hello_gosim__gosim_graph packages=1") ;;
  *)
    echo "unexpected output: ${output}" >&2
    exit 1
    ;;
esac
