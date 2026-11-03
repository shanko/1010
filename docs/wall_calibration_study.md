# Wall calibration follow-up (#36)

Protocol posted on issue #36 before calibration or evaluation on 2026-11-02.
Code revision: `3d31ff2`; game rules, features and the bundled model are unchanged.

The parent is recovered with `git show f5addb1:models/learned.json`. Before
screening, multiplier 0.75 was checked to reproduce every released weight
exactly. The comparator's resolved-model SHA-256 is
`4a06731303861400f195484161d1d974a077bc75e2f439aed19b23114f371203`.

For each multiplier m, subtract `(1-m) * parent.edge_cells` from `edge_cells`
and add it to `filled_neighbours`. No other weight changes. Candidates are
0.60, 0.65, 0.70, 0.80 and 0.85; the release is 0.75.

Screen on tuning seeds `2000200..2000999`, select the highest mean, and stop
if none beats the release mean. Confirm only that selection on
`2001000..2001999`; continue only if the paired 95% interval over the release
is entirely positive. All tuning seeds have been used in earlier work,
including confirmation of 0.75; neither range is untouched validation data.

Only after passing confirmation, freeze and publicly post the candidate
checksum and tuning results before evaluating it once on the reserved
`5000000..5001999` test range. Include all eight heuristics and the current
release. Never use that test result to select a different candidate.
Neither `3000000..3001999` nor `4000000..4001999` is used in this experiment.
The next unreserved test range is `6000000..6001999`.

Artifacts remain under ignored `learning_data/issue36/` on the compute
machine and are copied to the development machine. The runner is `run.rb`;
inputs are `parent.json` and `release.json`; candidates are in `models/`.
Phases produce `screening.json`, `confirmation.json` if reached, `selection.json`,
and `final.json` if reached, with logs and single-run markers. No experimental
model or per-seed report is committed. A fresh clone needs these ignored
artifacts to inspect the exact recorded run.

Commands from the repository root on the compute machine:

```sh
bundle exec ruby learning_data/issue36/run.rb screen
# Only if the screening mean gate passes:
bundle exec ruby learning_data/issue36/run.rb confirm
# Only after confirmation passes and frozen results are posted on GitHub:
bundle exec ruby learning_data/issue36/run.rb final
```

The runner uses 11 workers and records source, model and runner fingerprints.
A `.started` marker prevents silently repeating a phase. Model promotion
requires explicit maintainer approval; the experiment never overwrites the
bundled model.

## Screening results

800 reused tuning seeds, `2000200..2000999`.

| Multiplier | Mean score | Paired change vs release | 95% CI |
| --- | ---: | ---: | --- |
| 0.75 (release) | 418.775 | +0.000 | +0.000 to +0.000 |
| 0.60 | 411.655 | -7.120 | -27.665 to +13.425 |
| 0.65 | 415.840 | -2.935 | -24.599 to +18.729 |
| 0.70 | 422.382 | +3.607 | -17.658 to +24.873 |
| 0.80 | 405.185 | -13.590 | -34.562 to +7.382 |
| 0.85 | 388.295 | -30.480 | -51.736 to -9.224 |

The preregistered highest-mean rule selected 0.70. Its screening interval
crosses zero; screening alone does not establish an improvement.
Selected resolved-model SHA-256:
`a6764cc249f6fe7e6bbd0dafd76d01700f8e3c754b1ab27c4a61e44b20a81051`.

## Confirmation and stopping decision

On the 1,000 reused confirmation seeds `2001000..2001999`, the selected 0.70
candidate averaged **424.443**, versus **409.416** for the release. Its paired
gain was **+15.027 points/game**, with 95% CI **−3.304 to +33.358**.
The preregistered positive-interval gate failed. This is an inconclusive gain,
not proof that 0.70 is worse or that 0.75 is optimal.

The experiment stopped without freezing a candidate for final evaluation.
No final test seeds were evaluated, no final report or frozen model was created,
and no alternative candidate was tested after seeing confirmation. The reserved
`5000000..5001999` range remains unconsumed and reserved; `6000000..6001999`
remains the next unreserved range. The released model stays at multiplier 0.75;
there is no promotion proposal because the tuning gate did not pass.

`screening.json`, `confirmation.json`, `selection.json`, the five candidate
models, runner, inputs, logs and started markers were retained on both machines.
Independent inspection confirmed that only `edge_cells` and `filled_neighbours`
differ from the parent, with their occupied-contact sum preserved (within
floating-point precision).

Verification: full suite 192 tests, 1,100 assertions, zero failures/errors/skips;
`bundle exec rake lint` inspected 72 files with no offenses. The documented
100-seed/four-worker heuristic comparison printed
`PARITY OK: per-seed results match baseline-v4`. Its report is retained as
`learning_data/issue36-parity.json`. No gameplay or model bytes changed.
