# test_34_chain_nsw_only

> a chunked relaxation's only limit is the user's own NSW

## 1. Definition

Runs chunked relaxations until they stop by themselves, pushes one far past
every limit the chain used to impose, and checks that only NSW ends a chain
that is otherwise healthy.

## 2. Purpose

Besides the user's NSW, the chain used to carry three limits of its own:

| limit | value |
|---|---|
| chunks | 50 |
| accumulated VASP time | 48 h |
| calendar time since launch | 7 days, queue waits included |

Any of them could stop a long relaxation part way. `--resume` could not renew
them, so after the first one each resume bought exactly one more chunk. The
user asked for all three to go: NSW, and only NSW, decides how much a
relaxation may spend.

A chain launched by the previous version still has those limits written in its
state file. They must be ignored, not obeyed, when it resumes.

## 3. How it is executed

```
tests/run_all.sh test_34_chain_nsw_only
```

Same harness as test_29 (`tests/chain_harness.sh`): a fake scheduler and a fake
VASP, with the real `vasp_chain.sh`. About 15 seconds.

## 4. Expected results

| case | expected |
|---|---|
| NSW = 100, 30 s per step, 60-min chunks, `EDIFFG` out of reach | stops with `nsw_budget` at exactly **100** steps, in six chunks: **3 6 12 24 48 7** |
| a chain at chunk 60, with 100 h of VASP time, launched 30 days ago, with the old `max_chunks`, `max_wall_min` and `deadline_epoch` in its state | the chunk ends CONTINUE and the next chunk is submitted; `chain.log` mentions none of the old limits |
| a chain the old limits had stopped (`stop_reason=budget`) | `--resume` succeeds and the next chunk runs on |
| `--max-chunks 10` | refused as an unknown option |
| `--help` | mentions no chunk or time limit |
| `--walltime 1:30`, `--walltime 90.5` | refused: "whole minutes" |

The six caps follow from the chain's own rule: a warm chunk holds
`⌊3290 s / (30 s × 1.15)⌋ = 95` steps, the cap may at most double, and the last
chunk takes what is left of NSW (100 − 93 = 7).

`EDIFFG` is set to −0.0001 in the first case because the fake VASP's forces
keep falling. At the harness's −0.01 the chain would rightly **converge** on
them in chunk 5, and the case would never reach NSW.

## 5. Obtained results

All nine as expected.

Run against the previous version of `vasp_chain.sh` (the last commit before
this change), six of the nine fail: the chain stops at chunk 60 with
`reason=budget`, `--max-chunks` is accepted, and `--walltime 1:30` is not
refused for its format.

Package changes behind this test, in `vasp_chain.sh`:

1. The three limits, their state keys, the `--max-chunks` option and the
   `budget` stop reason are removed. What `--status` reports about compute
   used and core-hours stays: it is information, not a limit.
2. `--walltime` must be whole minutes. The chain's `int()` keeps only the
   digits of a value, so `1:30` meant 130 min and `90.5` meant 905 min.

## 6. Pass / fail criterion

Exact: the stop reason, the step count, the six caps, the submission count,
the chain state, and the refusals with their stated reason.

## 7. Verdict

**PASSED** — 9 assertions, 0 failed. See `logs/run.log`.

## Sources

- `NSW` is the maximum number of ionic steps, the budget a single VASP run
  would have had — <https://vasp.at/wiki/NSW>
- `EDIFFG < 0` stops the relaxation when every force is below `|EDIFFG|` —
  <https://vasp.at/wiki/EDIFFG>
