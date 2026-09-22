# Shared helpers for the WolfPack-DFT test suite.
#
# TWO RULES, both learned the hard way.
#
# 1. A CHECK NEVER GLOBS OUTSIDE cases/. The previous harness built its fixture
#    list with `find "$TK_DIR/Test" -name OUTCAR`, i.e. "test against whatever
#    happens to be lying around". When the harness moved under Test/ that swept
#    its own scratch files: 27 cases became 927, five minutes became two hours,
#    and the suite was grading itself on its own throwaway output. Fixtures are
#    NAMED, and they come from cases/.
#
# 2. PATHS ARE FOUND BY MARKER, NOT BY COUNTING DIRECTORIES UP. `dirname` of a
#    `dirname` breaks the moment anything moves, and things move.

SUITE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK_DIR="$SUITE_DIR"
while [[ "$TK_DIR" != "/" && ! -f "$TK_DIR/wolfpack.sh" ]]; do TK_DIR="$(dirname "$TK_DIR")"; done
[[ -f "$TK_DIR/wolfpack.sh" ]] || { echo "suite/lib.sh: no wolfpack.sh above $SUITE_DIR" >&2; exit 2; }

CASES="$SUITE_DIR/cases"
# Each test is a folder: test_NN_name/{check.sh, README.md, logs/}. The log of
# a run is written by run_all.sh, which creates the directory -- a check does
# not need to know where its own evidence goes.
WORK="${WP_SUITE_WORK:-$SUITE_DIR/work}"
mkdir -p "$WORK"

# Keep Python bytecode out of the toolkit tree.
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$WORK/pycache}"
export PYTHONDONTWRITEBYTECODE=

# --- the environment under test --------------------------------------------
WP_PY="${WP_PY:-$(command -v python3)}"
if [[ -x "$HOME/miniconda3/envs/wolfpack-dft/bin/python" ]]; then
    WP_PY="${WP_PY_OVERRIDE:-$HOME/miniconda3/envs/wolfpack-dft/bin/python}"
fi
# The toolkit's own environment on PATH. enumlib's enum.x / makestr.x live in
# the conda env's bin, and build-magnetic-configs looks for them on PATH: run
# the suite from a shell where that bin is absent and every magnetic ordering
# beyond the ferromagnet fails, for a reason that has nothing to do with the
# code under test.
PATH="$(dirname "$WP_PY"):$PATH"; export PATH

WP_VASP="${WP_VASP:-$HOME/Vasp.6.5.1/bin/vasp_std}"
WP_POTCAR_DIR="${WP_POTCAR_DIR:-$HOME/Vasp.6.5.1/Potentials/potpaw_PBE.64}"

# The testbed's slurm.conf. If the environment already points at a SLURM
# configuration, believe it: that is the one the running slurmctld was started
# with. Looking only inside our own work directory meant every live check
# skipped with "no reachable slurmctld" while SLURM was perfectly fine.
if [[ -n "${WP_TESTBED_ROOT:-}" ]]; then TESTBED_ROOT="$WP_TESTBED_ROOT"
elif [[ -n "${SLURM_CONF:-}" && -r "${SLURM_CONF:-}" ]]; then TESTBED_ROOT="$(dirname "$SLURM_CONF")"
else TESTBED_ROOT="/tmp/slurmtest"; fi

have_slurm(){ command -v sbatch >/dev/null 2>&1 && SLURM_CONF="$TESTBED_ROOT/slurm.conf" sinfo >/dev/null 2>&1; }
have_vasp(){  [[ -x "$WP_VASP" ]]; }
have_potcar(){ [[ -f "$WP_POTCAR_DIR/$1/POTCAR" ]]; }

# --- reporting --------------------------------------------------------------
_g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _b=$'\033[1m'; _x=$'\033[0m'
PASS_N=0; FAIL_N=0; SKIP_N=0
pass(){ PASS_N=$((PASS_N+1)); printf '  %s[ OK ]%s %s\n' "$_g" "$_x" "$*"; }
fail(){ FAIL_N=$((FAIL_N+1)); printf '  %s[FAIL]%s %s\n' "$_r" "$_x" "$*"; }
skip(){ SKIP_N=$((SKIP_N+1)); printf '  %s[SKIP]%s %s\n' "$_y" "$_x" "$*"; }
info(){ printf '  %s\n' "$*"; }

# assert helpers -- each states the CLAIM, so a failure reads as a broken
# promise rather than as a diff.
ok_if(){ local c="$1"; shift; if eval "$c"; then pass "$*"; else fail "$* [$c]"; fi; }

# Numeric comparison with a tolerance, for physical quantities.
near(){ # near VALUE TARGET TOL "claim"
    awk -v v="$1" -v t="$2" -v tol="$3" 'BEGIN{exit !(v!="" && (v-t<tol && t-v<tol))}' \
        && pass "$4  ($1 vs $2 +/- $3)" || fail "$4  (got $1, expected $2 +/- $3)"
}

# A command that MUST fail, and whose message must explain itself. A tool that
# dies with a traceback has not refused, it has crashed.
must_refuse(){ # must_refuse "claim" "regex the message must match" cmd...
    local claim="$1" rx="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        fail "$claim -- it was ACCEPTED"
    elif grep -qiE "Traceback \(most recent call last\)" <<<"$out"; then
        fail "$claim -- crashed with a traceback instead of refusing"
    elif grep -qiE "$rx" <<<"$out"; then
        pass "$claim"
    else
        fail "$claim -- refused, but the message does not say why: $(tail -1 <<<"$out" | cut -c1-90)"
    fi
}
