#!/usr/bin/env bash
# The linear-response U WORKFLOW: the three steps that come before the
# arithmetic that test_11 checks.
#
#   step 1  run-nscf-steps    perturbed runs at FIXED charge density (ICHARG=11)
#   step 2  run-scf-steps     the same perturbations, self-consistent
#   step 3  collect-u-data    read the occupations out of the OUTCARs
#   step 4  vasp-calculate-u  -> test_11
#
# The settings come from VASP's own worked example. What is checked is the
# PLUMBING: that the right folders are built, that each carries the LDAU tags
# it is supposed to, that ICHARG=11 is present in the NSCF step and absent from
# the SCF step -- because that single difference IS the two response functions
# -- and that the occupations are read back out correctly.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/u_workflow"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
NSCF="$TK_DIR/run_nscf_steps.sh"
SCF="$TK_DIR/run_scf_steps.sh"
COLLECT="$TK_DIR/collect_u_data.sh"

ALPHAS="-0.10 -0.05 0.05 0.10"

# --- a ground state to perturb ---------------------------------------------
# The ground state a real workflow leaves behind. run-nscf-steps requires
# CHGCAR and WAVECAR and is RIGHT to: the non-self-consistent step reads the
# converged density with ICHARG=11, and without it there is nothing to freeze.
# The first version of this test omitted them and read the tool's correct
# refusal as a failure.
mkdir -p gs
cp "$CASES/NiO/POSCAR" gs/POSCAR
printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > gs/KPOINTS
printf 'dummy POTCAR\n' > gs/POTCAR
printf 'dummy converged charge density\n' > gs/CHGCAR
printf 'dummy wavefunction\n' > gs/WAVECAR
cat > gs/INCAR <<'EOF'
SYSTEM = NiO ground state
ISPIN = 2
MAGMOM = 1.0 -1.0 0.0 0.0
LORBIT = 11
LMAXMIX = 4
PREC = A
EDIFF = 1E-6
ISMEAR = 0
SIGMA = 0.2
EOF

_tpl(){ cat > "$1" <<EOF
SYSTEM = NiO perturbed
ISPIN = 2
MAGMOM = 1.0 -1.0 0.0 0.0
LORBIT = 11
LMAXMIX = 4
PREC = A
EDIFF = 1E-6
ISMEAR = 0
SIGMA = 0.2
LDAU = .TRUE.
LDAUTYPE = 3
$2
EOF
}
_tpl nscf.incar "ICHARG = 11"
_tpl scf.incar ""

# The SLURM template each perturbed run is submitted with. run-nscf-steps
# requires one and says so by name; the first version of this test did not
# provide it and read the refusal as a failure to build the folders.
# The -J / -o / -e directives must be in SHORT form: run-nscf-steps rewrites
# them per alpha so each perturbed run gets its own job name and logs, and it
# says so with an example when they are missing. Written long-form first here,
# which the tool refused -- correctly.
cat > model_job.sh <<'EOF'
#!/bin/bash
#SBATCH -J uPROBE
#SBATCH -o uPROBE_%j.out
#SBATCH -e uPROBE_%j.err
#SBATCH --partition=local
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=00:10:00
srun vasp_std
EOF
chmod 755 model_job.sh

_outcar_stub(){ # _outcar_stub PATH DOCC -- a finished, CONVERGED NSCF run
    # run-scf-steps takes the occupations from the block that comes AFTER
    # "aborting loop because EDIFF is reached", delimited by "total charge"
    # and the following "magnetization" header. That is deliberate and right:
    # it reads the CONVERGED occupations, not an earlier iteration's. A stub
    # with the table before the marker is not a converged run and is correctly
    # rejected -- which is what happened the first four times this was written.
    #
    # The d occupancy is a PARAMETER because run-scf-steps also refuses when
    # every alpha produced the SAME table: that means the perturbation never
    # took effect, and the response would be zero. Writing one fixed table for
    # all four alphas is exactly that failure, and the tool caught it.
    local docc="${2:-8.450}"
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOS'
 vasp.6.5.1 synthetic
   LDAUTYPE =      3

 ------------------------ aborting loop because EDIFF is reached ----------------

 total charge

# of ion     s       p       d       tot
------------------------------------------
    1        0.412   0.588   __DOCC__   __TOT__
    2        0.412   0.588   8.400   9.400
--------------------------------------------------
tot          0.824   1.176  16.850  18.850

 magnetization (x)

# of ion     s       p       d       tot
------------------------------------------
    1        0.000   0.000   1.700   1.700
    2        0.000   0.000  -1.700  -1.700
--------------------------------------------------
tot          0.000   0.000   0.000   0.000

 reached required accuracy - stopping structural energy minimisation
 General timing and accounting informations for this job:
EOS
    sed -i -e "s/__DOCC__/$docc/" \
           -e "s/__TOT__/$(awk -v d="$docc" 'BEGIN{printf "%.3f", d+1.0}')/" "$1"
    # A non-empty WAVECAR: run-scf-steps requires one, because the
    # self-consistent step restarts from the perturbed wavefunction.
    printf 'dummy wavefunction\n' > "$(dirname "$1")/WAVECAR"
}

# --- the refusals, which are the cheap half --------------------------------
must_refuse "run-nscf-steps refuses without the LDAU templates" "ldaul|ldauu|required" \
    bash "$NSCF" --gs-dir gs --template nscf.incar --alphas "$ALPHAS" --dry-run
must_refuse "a LDAUU template with no {alpha} placeholder is refused" "alpha|placeholder" \
    bash "$NSCF" --gs-dir gs --template nscf.incar --alphas "$ALPHAS" \
        --ldaul "2 -1" --ldauu-template "0.1 0.0" --ldauj-template "0.1 0.0" --dry-run
must_refuse "a missing ground-state directory is refused by name" "not found|gs" \
    bash "$NSCF" --gs-dir nope --template nscf.incar --alphas "$ALPHAS" \
        --ldaul "2 -1" --ldauu-template "{alpha} 0.0" --ldauj-template "{alpha} 0.0" --dry-run
# The one that matters: the NSCF step IS the fixed-charge-density step. A
# template without ICHARG=11 would silently make it a second self-consistent
# run, and chi_0 would come out equal to chi -- a U of zero, with no error.
must_refuse "an NSCF template without ICHARG=11 is refused" "ICHARG" \
    bash "$NSCF" --gs-dir gs --template scf.incar --alphas "$ALPHAS" \
        --ldaul "2 -1" --ldauu-template "{alpha} 0.0" --ldauj-template "{alpha} 0.0" --dry-run
must_refuse "run-scf-steps refuses before run-nscf-steps has been run" "nscf|first|not found" \
    bash "$SCF" --gs-dir gs --nscf-dir missing_nscf --template scf.incar --alphas "$ALPHAS" \
        --ldaul "2 -1" --ldauu-template "{alpha} 0.0" --ldauj-template "{alpha} 0.0" --dry-run

# --- what the dry run BUILDS -----------------------------------------------
bash "$NSCF" --gs-dir gs --template nscf.incar --alphas "$ALPHAS" \
    --ldaul "2 -1" --ldauu-template "{alpha} 0.0" --ldauj-template "{alpha} 0.0" \
    --nscf-dir nscf --dry-run >nscf.log 2>&1 || true
n=$(find nscf -name INCAR 2>/dev/null | wc -l)
ok_if "[[ $n -eq 4 ]]" "one folder per alpha was prepared ($n for 4 alphas)"

# Every perturbation must carry ITS OWN alpha, in both LDAUU and LDAUJ. A
# template substituted once and reused would give four identical runs and a
# perfectly straight line through one point.
bad=0
for a in 0.10 -0.10 0.05 -0.05; do
    lbl=$(LC_NUMERIC=C printf "V_%+0.2f" "$a" | sed 's/\./p/')
    f="nscf/$lbl/INCAR"
    [[ -f "$f" ]] || { info "    missing $f"; bad=1; continue; }
    grep -qE "^LDAUU *=.*$a" "$f" || { info "    $lbl: LDAUU does not carry $a"; bad=1; }
    grep -qE "^LDAUJ *=.*$a" "$f" || { info "    $lbl: LDAUJ does not carry $a"; bad=1; }
    grep -qE "^ *ICHARG *= *11" "$f" || { info "    $lbl: NSCF step lost ICHARG=11"; bad=1; }
done
ok_if "[[ $bad -eq 0 ]]" "each alpha folder carries its own LDAUU/LDAUJ and keeps ICHARG=11"

# --- the SCF step is the same perturbation WITHOUT the frozen density ------
# Step 2 refuses until step 1 has actually COMPLETED, which is right: chi_0
# comes from those runs. The dry run above only prepared the folders, so give
# each one the OUTCAR a finished job would have left.
for a in -0.10 -0.05 0.05 0.10; do
    lbl=$(LC_NUMERIC=C printf "V_%+0.2f" "$a" | sed 's/\./p/')
    # dN = chi_0 * alpha with the tutorial's chi_0 = 0.50 (eV)^-1.
    [[ -d "nscf/$lbl" ]] && _outcar_stub "nscf/$lbl/OUTCAR" \
        "$(awk -v a="$a" 'BEGIN{printf "%.3f", 8.439 + 0.50*a}')"
done
bash "$SCF" --gs-dir gs --nscf-dir nscf --template scf.incar --alphas "$ALPHAS" \
    --ldaul "2 -1" --ldauu-template "{alpha} 0.0" --ldauj-template "{alpha} 0.0" \
    --scf-dir scf --dry-run >scf.log 2>&1 || true
n=$(find scf -name INCAR 2>/dev/null | wc -l)
ok_if "[[ $n -eq 4 ]]" "the self-consistent step prepared its four folders ($n)"
if (( n == 4 )); then
    grep -rqE "^ *ICHARG *= *11" scf/*/INCAR 2>/dev/null \
        && fail "the SCF step carries ICHARG=11: it is not self-consistent, and chi would equal chi_0" \
        || pass "the SCF step does NOT freeze the charge density"
fi

# --- collect-u-data reads the occupations back out -------------------------
# Synthetic OUTCARs carrying VASP's own numbers, so what is checked is the
# READING, not the physics: ground state 8.439, NSCF 8.488, SCF 8.452.
_outcar(){ # _outcar PATH DOCC
    mkdir -p "$(dirname "$1")"
    # "General timing and accounting informations" is VASP's farewell line, and
    # collect-u-data requires it in strict mode -- correctly: an OUTCAR without
    # it is a run that was cut off, and its occupations may be mid-iteration.
    cat > "$1" <<EOF
 vasp.6.5.1 synthetic
 total charge

# of ion     s       p       d       tot
------------------------------------------
    1        0.412   0.588   $2   $(awk -v d="$2" 'BEGIN{printf "%.3f", d+1.0}')
    2        0.412   0.588   8.400   9.400
--------------------------------------------------
tot          0.824   1.176  16.800  18.800

 General timing and accounting informations for this job:
 ========================================================
                  Total CPU time used (sec):        1.000
EOF
}
_outcar gsx/OUTCAR 8.439
for a in -0.10 -0.05 0.05 0.10; do
    lbl=$(LC_NUMERIC=C printf "V_%+0.2f" "$a" | sed 's/\./p/')
    _outcar "nscfx/$lbl/OUTCAR" "$(awk -v a="$a" 'BEGIN{printf "%.3f", 8.439 + 0.50*a}')"
    _outcar "scfx/$lbl/OUTCAR"  "$(awk -v a="$a" 'BEGIN{printf "%.3f", 8.439 + 0.12*a}')"
done
if bash "$COLLECT" --gs-dir gsx --nscf-dir nscfx --scf-dir scfx --alphas "$ALPHAS" \
       --site 1 --orbital d --output U_data.dat >collect.log 2>&1; then
    pass "collect-u-data read the perturbed OUTCARs"
    rows=$(grep -cvE '^#|^$' U_data.dat 2>/dev/null || echo 0)
    ok_if "[[ $rows -eq 4 ]]" "one row per alpha in U_data.dat ($rows)"
    # And the whole chain must land on the tutorial's U.
    u=$(cd "$W" && "$WP_PY" "$TK_DIR/vasp_calculate_u.py" 2>&1 | grep -oP '^U\s*=\s*\K-?[0-9.]+')
    near "${u:-}" 6.33 0.15 "the workflow end to end reproduces the tutorial's U"
else
    fail "collect-u-data failed: $(tail -1 collect.log)"
fi
exit $(( FAIL_N > 0 ))
