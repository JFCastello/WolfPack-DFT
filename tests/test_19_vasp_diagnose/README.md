# test_19_vasp_diagnose

> vasp-diagnose: the root cause of a failure, and it must not be the wrong one

## 1. Definition

Plants the evidence each kind of VASP failure leaves in the SLURM logs and the
OUTCAR, runs `vasp-diagnose` on it, and checks it names the right cause **and
not the other one**.

## 2. Purpose

A diagnosis of a crash is believed more readily than almost any other output,
because by the time you run it you already know something went wrong and you
want a name for it. The wrong name sends you to fix the wrong thing: raising
the memory request for a job that was killed on walltime, or shortening a job
that was OOM-killed.

So the test is not only *"does it find a cause"* but **"does it find the right
one and not also the other"**.

## 3. How it is executed

```
tests/run_all.sh test_19_vasp_diagnose
```

Seconds. The failures are **synthesised**, not provoked — an OOM on this laptop
would take the laptop with it, and the evidence a real one leaves is a fixed,
documented string from `slurmstepd`.

## 4. Expected results

| evidence planted | must diagnose | must NOT also say |
|---|---|---|
| `Detected 1 oom-kill event(s) ... cgroup out-of-memory` | out of memory | walltime |
| `CANCELLED AT ... DUE TO TIME LIMIT` | walltime kill | memory |
| `forrtl: severe (174): SIGSEGV` + `core dumped` | crash | — |
| 60 SCF steps with `NELM = 60` and no "EDIFF is reached" | non-convergence | — |
| a healthy OUTCAR: `reached required accuracy` | **no failure cause at all** | anything |
| an empty directory | does not crash | — |

The OOM and walltime pair is the point. They are the two most common ways a
VASP job dies, the remedies are **opposite** — more memory versus less work per
job — and the evidence for each sits in the same file.

The healthy-run case is the negative control: a diagnoser that always finds
something passes the first four and fails this one.

## 5. Obtained results

All eight as expected: each cause identified, neither of the confusable pair
reported alongside the other, the healthy run left alone, the empty directory
handled.

No package bug was found here.

## 6. Pass / fail criterion

Exact, and **two-sided**: the right cause must appear and the confusable one
must not. Reporting both would be scored as a failure even though the right
answer is among them — a diagnosis that names two opposite remedies is not a
diagnosis.

**What is not asserted:** whether the surviving data is scientifically useful.
`vasp-diagnose` classifies data as FULL / PLOTTABLE / PARTIAL / NOT_USABLE,
which is a statement about **which files were written before the process died**
— plumbing, not physics.

## 7. Verdict

**PASSED** — 8 assertions, 0 failed. See `logs/run.log`.

## Sources

- SLURM's own wording for these failures: `oom-kill event(s)` and
  `DUE TO TIME LIMIT` are emitted by `slurmstepd` —
  <https://slurm.schedmd.com/slurm.conf.html>
- `NELM` and what happens when it is exhausted —
  <https://www.vasp.at/wiki/index.php/NELM>
