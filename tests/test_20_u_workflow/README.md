# test_20_u_workflow

> the four-step linear-response U workflow, end to end, against the VASP tutorial

## 1. Definition

Exercises the three steps that come **before** the arithmetic of
`test_11_uchain`:

```
step 1  run-nscf-steps     perturbed runs at FIXED charge density (ICHARG=11)
step 2  run-scf-steps      the same perturbations, self-consistent
step 3  collect-u-data     read the occupations out of the OUTCARs
step 4  vasp-calculate-u   -> test_11
```

## 2. Purpose

Priority is that the **pipeline works end to end without breaking**. The single
difference between step 1 and step 2 — `ICHARG = 11` present or absent — *is*
the difference between the two response functions. If step 1 lost it, χ₀ would
equal χ and U would come out zero, with no error anywhere.

So this checks the plumbing: the right folders, each carrying its own α in both
`LDAUU` and `LDAUJ`, `ICHARG = 11` in step 1 and absent from step 2, and the
occupations read back correctly.

## 3. How it is executed

```
tests/run_all.sh test_20_u_workflow
```

A NiO ground-state folder with the files a finished run leaves, then both steps
in `--dry-run`, then `collect-u-data` over synthetic OUTCARs carrying VASP's own
numbers, then `vasp-calculate-u`. No scheduler, no VASP. Under ten seconds.

## 4. Expected results

Five refusals, each naming what is wrong:

| given | must refuse because |
|---|---|
| no `--ldaul` / `--ldauu-template` | there is nothing to perturb |
| a template with no `{alpha}` placeholder | every α would get the same perturbation |
| a missing ground-state directory | named, not "something is wrong" |
| **an NSCF template without `ICHARG = 11`** | it would silently be a second self-consistent run |
| `run-scf-steps` before `run-nscf-steps` | χ₀ does not exist yet |

Then: four folders, each with its own α in `LDAUU` **and** `LDAUJ`,
`ICHARG = 11` present in step 1 and **absent** in step 2, four rows in
`U_data.dat`, and the chain ending at the tutorial's **U = 6.33 eV**.

## 5. Obtained results

All five refusals correct. Four α folders built, each carrying its own
`LDAUU`/`LDAUJ` and keeping `ICHARG = 11`; the self-consistent step built its
four and does **not** freeze the density; four rows collected; and

```
the workflow end to end reproduces the tutorial's U   (6.333 vs 6.33 +/- 0.15)
```

## 6. Pass / fail criterion

- every refusal above must happen **and** the message must name the cause;
- exactly four folders per step;
- `ICHARG = 11` present in step 1, absent in step 2 — this one is not a
  formality, it is the physics of the method;
- final U within ±0.15 eV of 6.33, which is loose enough for the 4-point fit
  and tight enough to exclude 0 (perturbation lost) and a sign flip.

## 7. Verdict

**PASSED** — 12 assertions, 0 failed. See `logs/run.log`.

## Sources

- **VASP wiki, "Calculate U for LSDA+U"** —
  <https://vasp.at/wiki/Calculate_U_for_LSDA%2BU>
- `ICHARG` and what 11 means —
  <https://www.vasp.at/wiki/index.php/ICHARG>
- `LDAUTYPE = 3` — the linear-response perturbation —
  <https://www.vasp.at/wiki/index.php/LDAUTYPE>

