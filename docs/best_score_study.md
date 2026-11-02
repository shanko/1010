# Study of the best-score recording

The maintainer supplied `my-best-score.moves` as a demonstration for improving
`learned`. A byte-identical original is preserved as
`learning_data/best-score-study/original.moves`. A working copy removes
one empty line (original line 150), which the strict trace parser rejects.
The cleaned trace replays legally to Game Over at **1,184 points**, with
**320 retained placements** and **two undo events**. Its recorded dealer seed,
`1009413778`, reproduces all recorded offers. The trace is labeled `replay`.

The source is an explicitly supplied external demonstration, outside the
repository's training, tuning and held-out seed ranges. It is not relabeled as
a training-split episode. Its final decisions after undo supply the examples;
the undone choices are not treated as targets.

## Comparison on the recorded offers

With the exact final-trajectory offer batches frozen, and policy tie-breaking
seed 17, the released learned player and Codex Sam each score **599** (164
placements); Sam scores **181** (49 placements). All reach Game Over before
the recorded offers run out. The demonstrated final sequence scores 1,184.
This fixed-offer counterfactual differs from normal seeded gameplay; the
human recording includes undo. It does not establish an average policy gain.

The released model's best-scoring action matches 83 of the 320 demonstrated
choices (within numerical tolerance). Across the 237 disagreements:

| Contact count per placement | Demonstrated choice | Model's choice |
|---|---:|---:|
| Walls only | 1.987 | 4.591 |
| Occupied cells | 4.089 | 4.489 |

This suggests testing wall preference separately from contact with existing
blocks. It is a hypothesis drawn from the demonstration, not proof that walls
are generally harmful. The model's `edge_cells` feature includes both wall
and occupied-cell contact; `filled_neighbours` counts occupied cells only.

## Experiment 1: direct demonstration fine-tuning

Each candidate starts from the released model and minimizes softmax imitation
loss on all 320 demonstrated decisions. Seed 17 shuffles examples. Seven
recipes use full demonstration targets; one blends demonstration targets and
the released model's original action probabilities equally. No original
training lesson or evaluation game is added to the demonstration dataset.

Screening uses tuning seeds `2000000..2000199`, paired against the release.

| Candidate | Learning rate | Epochs | Demonstration influence | Mean score | Paired change |
|---|---:|---:|---:|---:|---:|
| demo1 | 0.001 | 1 | 1.0 | 379.855 | -1.530 |
| demo2 | 0.003 | 1 | 1.0 | 378.795 | -2.590 |
| demo3 | 0.01 | 1 | 1.0 | 374.535 | -6.850 |
| demo4 | 0.03 | 1 | 1.0 | 367.695 | -13.690 |
| demo5 | 0.1 | 1 | 1.0 | 356.205 | -25.180 |
| demo6 | 0.01 | 3 | 1.0 | 358.745 | -22.640 |
| demo7 | 0.01 | 10 | 1.0 | 347.915 | -33.470 |
| demo8 | 0.03 | 3 | 0.5 | 351.820 | -29.565 |

The release mean is 381.385. All direct fine-tuning recipes reduce the screening
mean; none is promoted. Copying one successful trajectory does not necessarily
teach a general improvement.

## Experiment 2: isolate wall contact

Scale the released wall-contact coefficient by 0.9, 0.75, 0.5, 0.25 or 0.0,
while preserving its occupied-cell contact coefficient exactly. In feature
weights, subtract `delta` from `edge_cells` and add the same `delta` to
`filled_neighbours`. All other weights and all game rules stay fixed.
Use the same screening seeds. Choose the highest-mean candidate for a paired
confirmation on `2001000..2001999`; require the 95% interval for its gain over
the release to be entirely positive. If it passes, freeze it before one final
evaluation on the separately reserved seeds `4000000..4001999`. The previously
used held-out range is not consulted for selecting new weights.

## Preserved artifacts

Temporary code, models, reports and the source copy remain under
`learning_data/best-score-study/`. In particular, `audit.rb`, `compare-offers`,
`train-experiment`, `wall-experiment` and `run-experiment.sh` are retained.
The maintainer explicitly requested that temporary Ruby code not be cleared.
No raw recording or machine-specific path is committed.

### Wall calibration screening

| Wall multiplier | Mean score | Paired change vs release | 95% CI |
|---|---:|---:|---|
| 0.9 | 379.410 | -1.975 | -35.330 to +31.380 |
| 0.75 | 406.315 | +24.930 | -14.973 to +64.833 |
| 0.5 | 385.130 | +3.745 | -31.315 to +38.805 |
| 0.25 | 330.720 | -50.665 | -87.262 to -14.068 |
| 0.0 | 265.425 | -115.960 | -148.547 to -83.373 |

The selected multiplier is 0.75. On the separate 1,000 tuning seeds
`2001000..2001999`, it gains **+32.228 points/game** over the release
(95% CI **+14.860 to +49.596**). The confirmation interval clears zero.
The candidate was then frozen at resolved-model SHA-256
`4a06731303861400f195484161d1d974a077bc75e2f439aed19b23114f371203`
before the one final evaluation on reserved seeds `4000000..4001999`.

## Bounded improvement search

The existing `improve` command searched with 20,000 states, up to 100 search
rollouts, beam width 4 and a 120-second safety cap. It did not find a complete
trajectory above 1,184. The saved output is a replayable version of the
320-move baseline; failure to improve within this budget is not optimality
proof. Rollout-based move-cost estimates use Sam and should not be treated as
proven mistakes in a stronger demonstrated trajectory.

## Frozen final evaluation and release

The one final evaluation used all 2,000 reserved seeds `4000000..4001999`,
with all eight heuristics, the previous release and the frozen candidate.
These seeds were not used for training, screening or confirmation. The model
was frozen before evaluation and its fingerprint verified afterward.

| Policy | Mean score | 95% CI for mean | Median | P10 / P90 | Maximum |
|---|---:|---|---:|---|---:|
| codex_sam | 323.884 | 317.356 to 330.411 | 291 | 170 / 514 | 1232 |
| released | 364.123 | 356.020 to 372.227 | 320 | 182 / 594 | 2197 |
| learned | 407.738 | 397.817 to 417.660 | 354 | 192 / 709 | 2860 |

| Paired difference | Mean | 95% CI | Wins / ties / losses |
|---|---:|---|---|
| learned minus released | +43.615 | +31.528 to +55.702 | 1075 / 133 / 792 |
| learned minus codex_sam | +83.855 | +72.745 to +94.965 | 1203 / 117 / 680 |

Both paired intervals are entirely positive. The confirmed candidate replaces
the bundled `models/learned.json`, retaining the strategy name `learned`.
This improves average performance; it does not guarantee a new record in
every session, or establish that every demonstrated choice was optimal.

Only two weights change: `edge_cells` is multiplied by 0.75, and the removed
weight is added to `filled_neighbours`. Writing W for wall contact and B for
occupied-cell contact, the original contact score was proportional to
`35.5802 W + 36.6477 B`. It becomes `26.6852 W + 36.6477 B` (both divided by
32 in feature scaling). All other feature coefficients are unchanged.

The demonstration thus informed a targeted, tested calibration rather than
being copied blindly. Its raw source SHA-256 is
`908611040d79b6be97dae8f7a3a6e14689f4a3997a6684d33c72aa07759f5535`.
The cleaned trace SHA-256 is
`4de0d6f03f8b0f0fd99b4e9a68639eac1cf87ee078ab00bec78c5efecefa3871`.
The parent model is identified in `models/README.md` and remains in Git history
and the ignored `released-before-study.json` artifact.

### Reproduction

All temporary experiment code remains in `learning_data/best-score-study/`.
On the designated compute checkout, the recorded sequence was:

```sh
bash learning_data/best-score-study/run-experiment.sh
bundle exec ruby learning_data/best-score-study/wall-experiment
bundle exec ruby learning_data/best-score-study/confirm-experiment
```

The runner includes training. The confirmation
runner freezes the best screening candidate, records the independent tuning
gate, and evaluates new test seeds only if that gate passes. Future experiments
must reserve another test range instead of reusing these results for selection.
To replay the validated 1,184-point sequence, use:

```sh
./1010 learning_data/best-score-study/improved.moves
```

The `improved.moves` filename is the existing search command's output name;
its score stayed at 1,184. No stronger recorded sequence was found.

## Release verification

- `bundle exec rake test`: 161 tests, 915 assertions, zero failures/errors/skips.
- `bundle exec rake lint`: 56 files, no offenses, including preserved local
  experiment helpers (the checkout-only file count differs from CI).
- New `benchmarks/baseline-v6.json`: all eight heuristic per-seed results match
  v4/v5 exactly on baseline seeds 1–100; v5 remains unchanged.
- Independently recomputed final score means, paired differences and 95%
  intervals from per-seed data; verified all 2,000 seeds for every policy and
  the frozen resolved-model checksum.
- Replayed the normalized search output to its declared Game Over score of
  1,184, with all 320 retained moves legal.

Manual check: run `./1010 auto learned --seed 42`. Expected: the released
wall-calibrated policy plays legal moves through Game Over and auto restart.
The graphical window was not opened for this study.
