<!-- The required shape of every test_NN/README.md. -->

# test_NN_name

> one-line summary; run_all.sh reads this line

## 1. Definition
What this test is.

## 2. Purpose
Why it exists -- what failure it is designed to catch.

## 3. How it is executed
The command, the inputs, and roughly how long it takes.

## 4. Expected results
What the tool must produce, with the reference values and their SOURCES
(links). If a value cannot be traced to a source, it is not asserted.

## 5. Obtained results
What it actually produced on this machine, with numbers.

## 6. Pass / fail criterion
The exact condition, including tolerances and why they are those.

## 7. Verdict
**PASSED** or **FAILED**, with the assertion count and a pointer to `logs/run.log`.
On failure, the explanation goes in `logs/FAILURE.log`, not here.

## Sources
Links.
