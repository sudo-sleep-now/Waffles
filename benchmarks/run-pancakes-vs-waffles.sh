#!/usr/bin/env bash
set -euo pipefail

# Reproducible process-isolated matrix. Supply the pinned Pancakes checkout and
# the Luau executable explicitly, for example:
#   PANCAKES_DIR=/path/to/pancakes LUAU_BIN=/path/to/luau \
#     benchmarks/run-pancakes-vs-waffles.sh > /tmp/waffles-benchmark.txt

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
luau_bin=${LUAU_BIN:-luau}
pancakes_dir=${PANCAKES_DIR:-}
pinned_commit=${PANCAKES_COMMIT:-0c03c004a1600c2380e2ca00977256773b156ff6}

if [[ -z "$pancakes_dir" ]]; then
	echo "PANCAKES_DIR must point to the pinned Pancakes checkout" >&2
	exit 2
fi
if [[ ! -x "$luau_bin" ]]; then
	echo "LUAU_BIN is not executable: $luau_bin" >&2
	exit 2
fi
actual_commit=$(git -C "$pancakes_dir" rev-parse HEAD 2>/dev/null || true)
if [[ "$actual_commit" != "$pinned_commit" ]]; then
	echo "Pancakes checkout is $actual_commit; expected $pinned_commit" >&2
	exit 2
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/waffles-benchmark.XXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

mkdir -p "$stage/Waffles/Internal" "$stage/Pancakes"
cp "$repo_root/src/init.luau" "$stage/Waffles/init.luau"
cp "$repo_root/src/init.luau" "$stage/Waffles/main.luau"
cp "$repo_root/src/Internal/"*.luau "$stage/Waffles/Internal/"
cp "$repo_root/src/Settings.luau" "$stage/Waffles/Settings.luau"
sed -E -i \
	's#require\(script\.Settings\)#require("./Settings")#g; s#require\(script\.Internal\.([A-Za-z]+)\)#require("./Internal/\1")#g' \
	"$stage/Waffles"/*.luau
sed -E -i 's#require\(script\.Parent\.Tags\)#require("./Tags")#g' "$stage/Waffles/Internal/"*.luau

pancakes_src="$pancakes_dir/src"
if [[ ! -f "$pancakes_src/init.luau" ]]; then pancakes_src="$pancakes_dir"; fi
cp "$pancakes_src/init.luau" "$stage/Pancakes/main.luau"
cp "$pancakes_src/Settings.luau" "$stage/Pancakes/Settings.luau"
sed -E -i \
	's#require\(script\.Settings\)#require("./Settings")#g; s#local HttpService = game:GetService\("HttpService"\)#local HttpService = {JSONEncode = function(_self, _data) return "" end}#' \
	"$stage/Pancakes/main.luau"
cp "$repo_root/benchmarks/benchmark-cli.luau" "$stage/benchmark-cli.luau"

echo "# runtime=$luau_bin pancakes_commit=$actual_commit optimize=2 processes=5" >&2
for _run in 1 2 3 4 5; do
	for target in pancakes waffles; do
		for mode in auto schema; do
			for count in 40 120; do
				(
					cd "$stage"
					"$luau_bin" -O2 benchmark-cli.luau -a "$target" "$mode" "$count"
				)
			done
		done
	done
done
