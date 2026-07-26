#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="${HOME}/git"
DRY_RUN=1
PATTERNS=('target' 'node_modules' '\.venv' 'venv')
MAX_DEPTH=3
PATH_BUDGET=110 # keeps the full line (size + path) under 130 chars

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

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Dry run: matches under $display_dir (nothing will be deleted)"
	echo
fi

total_kb=0
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
	fi
done < <(fd -t d -H -I --prune --max-depth "$MAX_DEPTH" -0 "$pattern_regex" "$TARGET_DIR" \
	| xargs -0 -P "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" -I{} du -sk {} \
	| sort -rn \
	| tr '\n' '\0')

total_human=$(format_kb "$total_kb")
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "Would free approximately ${total_human}. Re-run with -d/--delete to delete."
else
	echo "Freed approximately ${total_human}."
fi
