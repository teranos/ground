#!/bin/sh
# The tests a change against $1 can reach: the tests that import a changed module,
# its own _test.d, and the tests that read the shipped controls when a pbt moved.
base=$1
changed=$( (git diff --name-only "$base"; git ls-files --others --exclude-standard) | sort -u)
for f in $changed; do
  case "$f" in
    source/*_test.d)
      [ -f "$f" ] && echo "$f" ;;
    source/*.d)
      mod=$(echo "${f#source/}" | sed 's|\.d$||; s|/|.|g')
      grep -lE "import ${mod}[ ;:,]" source/*_test.d ;;
    controls/*.pbt)
      grep -l "allParsed" source/*_test.d ;;
  esac
done | sort -u | tr '\n' ' '
