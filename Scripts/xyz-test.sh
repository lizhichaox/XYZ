#!/bin/sh
# Exercises path resolution in Resources/bin/xyz without launching the app.
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cli="$root/XYZ/Resources/bin/xyz"
fail=0

expect() {
  name=$1
  got=$2
  want=$3
  if [ "$got" = "$want" ]; then
    echo "ok $name"
  else
    echo "FAIL $name"
    echo "  got:  $got"
    echo "  want: $want"
    fail=1
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/notes"
printf 'hi\n' > "$tmp/notes/file.md"

out=$(XYZ_CLI_DRY_RUN=1 "$cli" --help | head -n 1)
expect help "$out" "Usage: xyz [options] [path ...]"

out=$(cd "$tmp" && XYZ_CLI_DRY_RUN=1 "$cli" .)
expect dot "$out" "open -b com.lizhichao.XYZ $tmp"

out=$(cd "$tmp" && XYZ_CLI_DRY_RUN=1 "$cli" notes/file.md)
expect file "$out" "open -b com.lizhichao.XYZ $tmp/notes/file.md"

out=$(cd "$tmp" && XYZ_CLI_DRY_RUN=1 "$cli" -n notes . )
expect multi "$out" "open -n -b com.lizhichao.XYZ $tmp/notes $tmp"

if XYZ_CLI_DRY_RUN=1 "$cli" "$tmp/missing" >/dev/null 2>"$tmp/err"; then
  echo "FAIL missing should exit non-zero"
  fail=1
else
  err=$(cat "$tmp/err")
  expect missing "$err" "xyz: $tmp/missing: No such file or directory"
fi

out=$(XYZ_CLI_DRY_RUN=1 "$cli")
expect bare "$out" "open -b com.lizhichao.XYZ"

exit "$fail"
