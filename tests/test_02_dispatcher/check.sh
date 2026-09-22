#!/usr/bin/env bash
# `wolfpack`: the front door. Every command it advertises must exist and run,
# and anything it does not advertise must be refused rather than guessed at.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# --- every advertised command resolves to a file that exists ---------------
# A dispatcher entry pointing at a missing file is invisible until a user types
# that command, and then it fails in the least helpful way possible.
missing=0; total=0
while IFS='|' read -r cmd file; do
    [[ -z "$cmd" ]] && continue
    total=$((total+1))
    [[ -f "$TK_DIR/$file" ]] || { info "    $cmd -> $file MISSING"; missing=$((missing+1)); }
done < <(grep -oE '"[a-z0-9-]+\|[a-z0-9_]+\.(sh|py)"' "$TK_DIR/install.sh" | tr -d '"')
(( total > 0 )) && ok_if "[[ $missing -eq 0 ]]" \
    "all $total advertised commands resolve to a file that exists"

# --- every command renders its own help without running anything -----------
# --help is the one thing a user types when they are already confused. It must
# not need a calculation directory, must not hang, and must not exit non-zero.
for f in "$TK_DIR"/vasp_*.sh "$TK_DIR"/build_*.py "$TK_DIR"/vasp_*.py "$TK_DIR"/wolfpack.sh; do
    [[ -f "$f" ]] || continue
    b=$(basename "$f")
    # .py files carry a #!/usr/bin/env python3 shebang, which resolves to the
    # BASE interpreter -- the one without pymatgen. Run them with the
    # interpreter the toolkit is actually installed into, or this check
    # measures the shebang rather than the program.
    if [[ "$b" == *.py ]]; then
        out=$(cd "$WORK" && timeout 25 "$WP_PY" "$f" --help 2>&1) || out="$out"
    else
        out=$(cd "$WORK" && timeout 25 bash "$f" --help 2>&1) || out="$out"
    fi
    if [[ -z "$out" ]]; then
        fail "$b --help produced nothing (or hung)"
    elif grep -qiE "traceback \(most recent" <<<"$out"; then
        fail "$b --help crashed"
    elif grep -qiE "change the shell working directory" <<<"$out"; then
        # vasp-nuke has no --help handler: the argument falls through to
        # `cd "$1"`, so bash's own `cd` documentation is printed instead. It
        # deletes nothing (cd returns 2, and `|| exit 1` stops the script), but
        # the safest thing a user can type before a destructive command answers
        # with documentation for a different command.
        fail "$b --help prints bash's 'cd' documentation, not its own"
    else
        pass "$b --help works from an empty directory"
    fi
done

# --- an unknown subcommand is REFUSED, not silently ignored ----------------
must_refuse "wolfpack rejects an unknown subcommand" \
    "unknown|not a|usage|available" \
    bash "$TK_DIR/wolfpack.sh" definitely-not-a-command
exit $(( FAIL_N > 0 ))
