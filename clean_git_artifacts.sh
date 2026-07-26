#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="${HOME}/git"
DRY_RUN=1
PATTERNS=('target' 'node_modules' '\.venv' 'venv')
MAX_DEPTH=3
PATH_BUDGET=110 # keeps the full line (size + path) under 130 chars
NO_CACHE="${NO_CACHE:-false}"
CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/clean_git_artifacts/cache.tsv"
CACHE_TTL=300 # seconds; a cache hit still expires after this even if mtime is unchanged

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Find and remove Rust (target), Node (node_modules), and Python
(.venv/venv) build artifacts under a directory tree.

Options:
	-t, --dir DIR         Directory to scan (default: ~/git)
	-n, --dry-run         Show what would be deleted without deleting (default)
	-d, --delete          Actually delete matched directories
	-h, --help            Show this help message

Environment:
	NO_CACHE=true         Bypass the size cache; always du fresh

Examples:
	$(basename "$0")                  	# dry-run under ~/git
	$(basename "$0") -d                	# delete under ~/git
	$(basename "$0") -t ~/code -d       	# delete under ~/code
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-t|--dir)
			TARGET_DIR="$2"
			shift 2
			;;
		-n|--dry-run)
			DRY_RUN=1
			shift
			;;
		-d|--delete)
			DRY_RUN=0
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1
			;;
	esac
done

if [[ ! -d "$TARGET_DIR" ]]; then
	echo "Error: directory not found: $TARGET_DIR" >&2
	exit 1
fi

if ! command -v fd >/dev/null 2>&1; then
	echo "Error: fd is required but not installed" >&2
	exit 1
fi

pattern_regex="^($(IFS='|'; echo "${PATTERNS[*]}"))\$"
display_dir="${TARGET_DIR/#"$HOME"/"~"}"

truncate_path() {
	local path="$1"
	if (( ${#path} > PATH_BUDGET )); then
		local keep=$(( PATH_BUDGET - 3 ))
		echo "...${path: -${keep}}"
	else
		echo "$path"
	fi
}

format_kb() {
	local kb="$1"
	if (( kb >= 1024 * 1024 )); then
		awk -v kb="$kb" 'BEGIN { printf "%.1fG", kb / 1024 / 1024 }'
	elif (( kb >= 1024 )); then
		awk -v kb="$kb" 'BEGIN { printf "%.0fM", kb / 1024 }'
	else
		echo "${kb}K"
	fi
}

# Opportunistic size cache, keyed by matched directory path and its own
# mtime, shared on disk with the Zig binary (same TSV path and format). NOT
# a correctness guarantee: build tools routinely overwrite an existing file
# in place (e.g. a recompiled binary with the same name), which changes
# that file's size without touching its parent directory's mtime -- so a
# cache hit can under- or over-report versus a fresh du. A cache entry still
# expires after CACHE_TTL seconds even if mtime is unchanged, to bound that
# blind spot. Set NO_CACHE=true to bypass entirely for an accurate one-off
# measurement.
declare -A cache_mtime cache_size cache_time
now="$EPOCHSECONDS"
if [[ "$NO_CACHE" != "true" && -f "$CACHE_FILE" ]]; then
	while IFS=$'\t' read -r c_path c_mtime c_size c_time; do
		[[ -z "$c_path" ]] && continue
		cache_mtime["$c_path"]="$c_mtime"
		cache_size["$c_path"]="$c_size"
		cache_time["$c_path"]="$c_time"
	done < "$CACHE_FILE"
fi

mapfile -d '' -t match_dirs < <(fd -t d -H -I --prune --max-depth "$MAX_DEPTH" -0 "$pattern_regex" "$TARGET_DIR")
# fd appends a trailing slash to directory matches; strip it so paths match
# the Zig binary's (no trailing slash) for display parity and so both
# binaries key the shared cache file identically.
for i in "${!match_dirs[@]}"; do
	match_dirs[i]="${match_dirs[i]%/}"
done

declare -A fresh_mtime
results=()
to_compute=()

# One `stat` invocation for every match instead of one fork per match --
# forking `stat` per directory dominated wall time once the size cache made
# `du` itself free.
if (( ${#match_dirs[@]} > 0 )); then
	while IFS=$'\t' read -r m_mtime m_path; do
		fresh_mtime["$m_path"]="$m_mtime"
	done < <(stat -f $'%m\t%N' "${match_dirs[@]}" 2>/dev/null)
fi

for dir in "${match_dirs[@]}"; do
	mtime="${fresh_mtime[$dir]:-0}"
	if [[ "$NO_CACHE" != "true" && "${cache_mtime[$dir]:-}" == "$mtime" \
		&& $(( now - ${cache_time[$dir]:-0} )) -lt "$CACHE_TTL" ]]; then
		results+=("${cache_size[$dir]}"$'\t'"$dir")
	else
		to_compute+=("$dir")
	fi
done

if (( ${#to_compute[@]} > 0 )); then
	while IFS=$'\t' read -r -d '' size_kb dir; do
		results+=("$size_kb"$'\t'"$dir")
		cache_mtime["$dir"]="${fresh_mtime[$dir]}"
		cache_size["$dir"]="$size_kb"
		cache_time["$dir"]="$now"
	done < <(printf '%s\0' "${to_compute[@]}" \
		| xargs -0 -P "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" -I{} du -sk {} \
		| tr '\n' '\0')
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Dry run: matches under $display_dir (nothing will be deleted)"
	echo
fi

total_kb=0
if (( ${#results[@]} > 0 )); then
	while IFS=$'\t' read -r -d '' size_kb dir; do
		total_kb=$(( total_kb + size_kb ))
		size_human=$(format_kb "$size_kb")
		display_path="${dir/#"$HOME"/"~"}"
		display_path=$(truncate_path "$display_path")

		if [[ "$DRY_RUN" -eq 1 ]]; then
			printf '%8s  %s\n' "$size_human" "$display_path"
		else
			printf 'Removing %8s  %s\n' "$size_human" "$display_path"
			rm -rf -- "$dir"
			unset -v "cache_mtime[$dir]" "cache_size[$dir]" "cache_time[$dir]"
		fi
	done < <(printf '%s\n' "${results[@]}" | sort -rn | tr '\n' '\0')
fi

if [[ "$NO_CACHE" != "true" ]]; then
	mkdir -p "$(dirname "$CACHE_FILE")"
	tmp_cache="${CACHE_FILE}.tmp.$$"
	: > "$tmp_cache"
	for dir in "${!cache_mtime[@]}"; do
		printf '%s\t%s\t%s\t%s\n' "$dir" "${cache_mtime[$dir]}" "${cache_size[$dir]:-0}" "${cache_time[$dir]:-0}" >> "$tmp_cache"
	done
	mv "$tmp_cache" "$CACHE_FILE"
fi

total_human=$(format_kb "$total_kb")
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Would free approximately ${total_human}. Re-run with -d/--delete to delete."
else
	echo "Freed approximately ${total_human}."
fi
