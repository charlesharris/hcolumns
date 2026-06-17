#!/usr/bin/env bash
#
# Install (or reinstall) the hcolumns gem locally so `hcol` is on your PATH.
# Idempotent: run it as often as you like — it always leaves exactly the current
# version installed, replacing any prior build.
#
#   ./install.sh        run tests, build, install
#   ./install.sh -s     skip tests (faster)
#   ./install.sh -h     this help
#
# For a quick dev run WITHOUT installing, use ./exe/hcol directly.

set -euo pipefail

cd "$(dirname "$0")"   # repo root, wherever this is invoked from

run_tests=1
case "${1:-}" in
  -s|--skip-tests) run_tests=0 ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

say() { printf '\033[34;1m→ %s\033[0m\n' "$*"; }

version="$(ruby -Ilib -rhcolumns/version -e 'print HColumns::VERSION')"
gemfile="hcolumns-${version}.gem"

if [[ "$run_tests" == 1 ]]; then
  say "tests"
  bundle exec rspec
fi

say "build hcolumns ${version}"
gem build hcolumns.gemspec

say "install (replacing any prior versions)"
gem uninstall hcolumns --all --ignore-dependencies --executables --quiet 2>/dev/null || true
gem install "./${gemfile}" --no-document
rm -f "./${gemfile}"

# rbenv installs the executable as a shim that only appears after a rehash.
if command -v rbenv >/dev/null 2>&1; then rbenv rehash; fi

printf '\033[32m✓ installed hcolumns %s — run `hcol help`\033[0m\n' "$version"
