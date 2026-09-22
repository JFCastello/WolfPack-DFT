#!/usr/bin/env bash
# WolfPack-DFT test suite.
#
#   tests/run_all.sh                   # everything, in order
#   tests/run_all.sh test_13_plots     # one test
#   tests/run_all.sh --list            # what there is
#
# Every check is ADVERSARIAL: it tries to make the tool do the wrong thing, and
# where the tool makes a physical claim it is compared against a published
# value. The cases are textbook benchmarks that converge in seconds on this
# laptop -- see cases/make_cases.py for what each one is FOR.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# The tests, in the order they run: foundations first, then units, then the
# live ones that need a scheduler and a VASP. Discovered from the folders, so
# adding test_17_* is all it takes to add a test.
mapfile -t ORDER < <(cd "$SUITE_DIR" && ls -d test_[0-9]* 2>/dev/null | sort)

_what(){ sed -n 's/^> *//p' "$SUITE_DIR/$1/README.md" 2>/dev/null | head -1; }

[[ "${1:-}" == "--list" ]] && { for k in "${ORDER[@]}"; do printf '  %-22s %s\n' "$k" "$(_what "$k")"; done; exit 0; }
SEL=("$@"); (( ${#SEL[@]} )) || SEL=("${ORDER[@]}")

t0=$SECONDS; failed=(); skipped=(); n_pass=0; n_fail=0; n_skip=0
for k in "${SEL[@]}"; do
    s="$SUITE_DIR/$k/check.sh"
    [[ -x "$s" ]] || { echo "no such test: $k (expected $s, executable)"; exit 2; }
    printf '\n%s\n %s -- %s\n%s\n' \
        "==============================================================" \
        "$k" "$(_what "$k")" \
        "=============================================================="
    # The run's own evidence, kept beside the README that explains it.
    out="$SUITE_DIR/$k/logs/run.log"
    mkdir -p "$(dirname "$out")"
    bash "$s" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    n_pass=$(( n_pass + $(grep -c '\[ OK \]' "$out") ))
    n_fail=$(( n_fail + $(grep -c '\[FAIL\]' "$out") ))
    n_skip=$(( n_skip + $(grep -c '\[SKIP\]' "$out") ))
    (( rc != 0 )) && failed+=("$k")
    grep -q '\[SKIP\]' "$out" && skipped+=("$k")

    # A test that passes says so in its README. A test that FAILS has to say
    # what happened somewhere a reader will find it without reading 200 lines
    # of OK, so the failing assertions are lifted into their own file. It is
    # removed on a passing run, so its presence always means the LAST run of
    # this test failed -- a stale one would be worse than none.
    fl="$SUITE_DIR/$k/logs/FAILURE.log"
    nf_this=$(grep -c '\[FAIL\]' "$out")
    if (( nf_this > 0 || rc != 0 )); then
        {
            printf '%s FAILED -- %s\n' "$k" "$(date '+%Y-%m-%d %H:%M:%S')"
            printf '%s\n\n' "-------------------------------------------------------------"
            printf 'what the test is: %s\n' "$(_what "$k")"
            printf 'exit status     : %s\n' "$rc"
            printf 'assertions      : %s failed of %s\n\n' \
                "$nf_this" "$(( nf_this + $(grep -c '\[ OK \]' "$out") ))"
            printf 'THE FAILING ASSERTIONS\n\n'
            sed 's/\x1b\[[0-9;]*m//g' "$out" | grep '\[FAIL\]'
            printf '\nWHAT TO DO WITH THIS\n\n'
            printf '  1. Read the assertion above: it states the CLAIM that was broken,\n'
            printf '     not a diff. section 6 of %s/README.md says why that\n' "$k"
            printf '     tolerance and not another.\n'
            printf '  2. Before changing anything in the package, confirm the failure is\n'
            printf '     the PIPELINE and not the test, then check the source cited in\n'
            printf '     section "Sources" of the README. See ../RULES.md.\n'
            printf '  3. Full evidence, in order, is in run.log beside this file.\n'
        } > "$fl"
        printf '  %s-> wrote %s%s\n' "$_r" "${fl#"$SUITE_DIR"/}" "$_x"
    else
        rm -f "$fl"
    fi
done

printf '\n%s\n summary  (%ss)\n%s\n' \
    "==============================================================" \
    "$((SECONDS-t0))" \
    "=============================================================="
printf '  ran      : %s\n' "${SEL[*]}"
printf '  assertions: %s passed, %s failed, %s skipped\n' "$n_pass" "$n_fail" "$n_skip"
(( ${#skipped[@]} )) && printf '  skipped  : %s\n' "${skipped[*]}"
if (( ${#failed[@]} )); then printf '  %sFAILED   : %s%s\n' "$_r" "${failed[*]}" "$_x"; exit 1; fi
printf '  %sall checks passed%s\n' "$_g" "$_x"
