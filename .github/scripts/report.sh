#!/usr/bin/env bash
# Runs a command and, if it fails, repeats its output as a workflow annotation.
#
#   report.sh <label> <command> [args...]
#
# Why this exists: downloading a job log from the Actions API needs a token,
# while annotations on a public repository are readable without one. A failing
# build otherwise reports nothing but "Process completed with exit code 1" to
# anyone working without credentials — and since neither Android nor iOS can be
# built on the development machine for this project, CI *is* the compiler, and
# its output is the only account of what went wrong.
#
# The whole output goes into ONE annotation rather than one per line, because
# GitHub shows only the first handful of error annotations per step and an
# analyzer complaint is rarely the first line.
set -uo pipefail

label="$1"
shift

out="$(mktemp)"
"$@" 2>&1 | tee "$out"
status="${PIPESTATUS[0]}"

if [ "$status" -ne 0 ]; then
  # Annotation messages are single-line; newlines are carried as %0A, and the
  # escape character itself has to be escaped first or any literal % in the
  # output would corrupt the rest of the message.
  message="$(
    sed -e 's/%/%25/g' -e 's/\r/%0D/g' "$out" |
      awk '{ printf "%s%%0A", $0 }'
  )"
  printf '::error title=%s failed::%s\n' "$label" "$message"
fi

rm -f "$out"
exit "$status"
