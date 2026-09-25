# WolfPack-DFT — test suite

33 tests. They ship with the toolkit, so what is checked can be read rather
than taken on trust.

**No POTCAR is here, or anywhere in this repository.** They carry
`COPYR = ... regulated by the VASP license agreement` and may not be
redistributed. The tests read yours from `$WP_POTCAR_DIR` (default
`~/Vasp.6.5.1/Potentials/potpaw_PBE.64`) and skip cleanly when one is absent,
as they do without VASP or without a scheduler.

Everything a run produces — including the POTCARs the fixtures copy in — lands
in `tests/work/`, which is git-ignored and safe to delete at any time.

```
tests/run_all.sh                    # everything, in order
tests/run_all.sh test_13_plots      # one test
tests/run_all.sh --list             # what there is
```

The live tests need the SLURM testbed. It lives **outside** the repo, so that
cleaning the repo cannot delete it:

```
bash tests/slurm_testbed.sh         # builds/starts it in /tmp/wpslurm
export SLURM_CONF=/tmp/wpslurm/slurm.conf
```

Results of the last run: each test's `logs/run.log`, and the verdict in
section 7 of its `README.md`.
The rules this suite is written under: **[RULES.md](RULES.md)**.

## Layout

Every test is a folder with the same things:

```
test_NN_name/
  check.sh      the test
  README.md     what it tests, and why -- seven sections, see TEMPLATE.md
  logs/
    run.log     the evidence of the last run
    FAILURE.log written only when the last run FAILED; deleted when it passes
```

The README is the test: definition, purpose, how it runs, expected results,
obtained results, the pass/fail criterion, the verdict, and the sources every
physical number comes from. Nothing else belongs in it — in particular, no
running commentary about how the test itself was arrived at, because that
reads as a finding about the toolkit when it is not one.


## The tests

| | what it covers |
|---|---|
| `test_01_cases` | the benchmark cells themselves, against published PBE values |
| `test_02_dispatcher` | every advertised command resolves; every `--help` works |
| `test_03_configure` | the cluster profile: round-trip, hand edits, bad values |
| `test_04_supercell` | supercell arithmetic, against answers derived not copied |
| `test_05_structure` | the POSCAR→CONTCAR diff, against an injected deformation |
| `test_06_clean_nuke` | the two commands that delete: what they must NOT delete |
| `test_07_dryrun` | stage 1: refusals, and not claiming what it did not measure |
| `test_08_recommend` | the parallelization rules, judged per regime (DFT vs GW) |
| `test_09_chain_math` | `vasp-scf-loop`'s refusals: runs that would produce nothing |
| `test_10_magnetic` | magnetic orderings and MAGMOM/POSCAR site alignment |
| `test_11_uchain` | the linear-response U arithmetic and its refusals |
| `test_12_slurm_report` | sacct parsing and the three efficiency ratios |
| `test_13_plots` | the figures, and the gap the data behind them carries |
| `test_14_recommend_live` | every generated job script, on a live slurmctld |
| `test_15_pipeline_live` | dry-run → recommend → test, end to end, with VASP |
| `test_16_chain_live` | chunked vs one long run: same energy, same structure |
| `test_17_vasp_tutorial_magnetism` | the VASP magnetism tutorial, reproduced |
| `test_18_vasp_check` | the post-mortem, on runs whose answer is known |
| `test_19_vasp_diagnose` | why a run died — and not the other cause |
| `test_20_u_workflow` | the four-step U workflow end to end, vs the VASP tutorial |
| `test_21_incar` | the INCAR editor's four rules, and its two-copy drift gate |
| `test_22_geometry` | nodes × ranks: five invariants over 2025 layouts |
| `test_23_scaling` | stage 3's extrapolation: measure small, run big |
| `test_24_alloc_profiles` | whole-nodes vs balanced: n x m = ntasks, exactly |
| `test_25_chain_structure` | what a CHAINED relaxation changed, not its last chunk |
| `test_27_magmom_flag` | --magmom: magnitudes change, orderings do not |
| `test_28_bench_failed` | a benchmark that died must not size production |
| `test_32_queue_study` | `backfill-study`: the queue wait, quartiles, fairshare, prediction |
| `test_33_chain_live_e2e` | `vasp-relax-loop` for real: pipeline, VASP, SLURM; estimate vs time used |
| `test_35_steptime` | an ionic step measured, or extrapolated from a cut-off SCF |
| `test_36_relax_loop` | `vasp-relax-loop`: NSW per chunk, walltime per chunk, clean retries |

test_36 drives the real `vasp_relax_loop.sh` through `chain_harness.sh`: fake
`sbatch`, `squeue`, `sacct`, `scontrol` and a fake VASP behind `srun`, each
doing exactly what the test scripts. That is how a chunk can be made to run out
of its walltime, die of an OOM, or die with its whole job, on demand. test_33
runs the same chain for real.

## Adding one

Make `test_NN_name/check.sh`, source `../lib.sh`, use `pass` / `fail` / `skip`
/ `ok_if` / `near` / `must_refuse`, and end with `exit $(( FAIL_N > 0 ))`.
`run_all.sh` discovers the folder by name; nothing needs registering. Copy
`TEMPLATE.md` for the README.

