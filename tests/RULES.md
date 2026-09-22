# Rules for this suite

Three rules, each written after it was broken.

---

## 1. A physical number is taken from a SOURCE, never from reasoning

**What went wrong.** `vasp-calculate-u` computes the linear-response Hubbard U
as `U = 1/chi - 1/chi_0`. I reasoned that a positive perturbation α should
*repel* electrons from the site, so both response slopes would be negative, so
that expression would return a negative U — and "fixed" the formula.

VASP's own worked example says the opposite, in numbers:

```
ground state     d occupancy  8.439
non-selfconsistent            8.488     <- the occupancy RISES
```

α *attracts* electrons. Both slopes are positive. `1/chi - 1/chi_0` is
positive, the original code was right, and my "fix" broke working code that
had been correct all along. Reverted.

**The rule.** A test that asserts a physical value cites where the value came
from, with a link, in its `README.md`. If the number cannot be traced to a
published source or to a run of the tool's own documented example, the test
does not assert it.

Synthetic data is still allowed — it is the only way to check arithmetic
exactly — but the **slopes, signs and magnitudes fed into it** must come from
a real worked example, not from an argument about which way electrons move.

Preferred sources, in order:

1. A VASP wiki **tutorial with its own numbers**, reproduced with its own input
   files. `test_11_uchain` and `test_17_vasp_tutorial_magnetism` do this.
2. A published paper, cited by DOI or arXiv id, with the table quoted.
3. A value so standard it appears in an undergraduate textbook, named as such.

---

## 2. The job is plumbing. It never judges the physics

This toolkit builds pipelines. It does not decide whether a calculation is a
good idea, does not correct a user's tags, and does not substitute values the
user did not ask for.

So a test asserts things like:

- the INCAR the recommender wrote carries the KPAR it recommended
- `MAGMOM` lines up with its own `POSCAR`, site for site
- chunking a relaxation changes neither the energy nor the structure
- a missing input is refused **by name**, before a job is queued

and never things like:

- this ENCUT is too low for this POTCAR
- this magnetic ordering is the ground state
- this U is the right U for your material

Where a tool *does* refuse on physical grounds, it is because the pipeline
cannot work otherwise — a chunked MD loses its thermostat state; a chunked
cell relaxation pays the Pulay error once per boundary — and the refusal says
so and can be overridden with `--force`.

**Validation of cluster parameters is not physics.** Core counts, memory and
walltimes are arithmetic, and `--max-cores abc` is a typo, not a preference.

---

## 3. A check that passes for the wrong reason is worse than no check

Twenty-odd of the checks in this suite were wrong when first written, and every
one of them looked fine:

| the check said | it was actually |
|---|---|
| `Fe: moment 1.85, expected 2.2` | reading the PAW *augmentation* line instead of the cell moment |
| `strain 1.000 %, expected 1.005 %` | reading the *lattice parameter* change, not the strain |
| `vasp-nuke ran while a chain was live` | the probe job id was invented, so squeue correctly said the chain was dead |
| `a cell relaxation at low ENCUT was accepted` | the POTCAR was empty, so the guard could not read ENMAX and never fired |
| `the report crashed` | the fake `sacct` emitted columns the tool never asks for |
| `no sacct: message does not mention accounting` | `PATH` still contained the real `sacct` |
| `a bands-only folder does not crash the plotter` | the plotter produced **0 figures of 6**; it refused cleanly, so there was no traceback to grep for |
| `slurmctld accepts the script stage 3 rewrote` | the geometry was passed on the command line, which *overrides* the script's — the scheduler was judging my flags |

The last two are the shape to watch for: the assertion was TRUE and meant
nothing. "It did not crash" is not "it worked"; "the scheduler accepted it" is
not "the scheduler accepted *that file*".

So:

- **Every guard gets a negative control.** If a test asserts that something is
  refused, another assertion must show the same code path *accepting* the valid
  case — otherwise a tool that refuses everything passes.
- **Anchor every grep.** `magnetization` appears twice in an OUTCAR and means
  two different things; so does a percentage in a structure report.
- **When a check fails, find out whether the tool or the check is wrong before
  changing either.** This is what saved `vasp-nuke --help` from being reported
  as a command that deletes your files on `--help`. It does not: `cd` returns
  2 and `|| exit 1` stops the script. Testing it in a sandbox took a minute and
  prevented a false alarm.

---

## Layout

```
tests/
  lib.sh                    shared helpers; pass/fail/skip; must_refuse; near
  run_all.sh                discovers test_NN_* folders, writes each one's log
  slurm_testbed.sh          a SLURM shaped like the cluster, in /tmp (see below)
  cases/                    the benchmark structures + their published values
  TEMPLATE.md               the required shape of every README
  test_NN_name/
    check.sh                the test
    README.md               what it tests, why that case, and its sources
    logs/run.log            the evidence of the last run
    logs/FAILURE.log        written only when the last run failed; deleted on a pass
```

The testbed lives in `/tmp/wpslurm`, **outside the repository**. A previous one
kept its state inside the test folder, so deleting the tests killed the
scheduler: `sinfo` kept answering while every `sbatch` failed with
`I/O error writing script/environment to file`.

No check globs outside `cases/`. The previous harness built its fixture list
with `find Test -name OUTCAR` — "test against whatever is lying around" — and
when it moved it swept its own scratch files: 27 cases became 927 and five
minutes became two hours.
