# Full-game learning evaluation — November 1, 2026

Milestones 0–7 are complete. The implementation was already present for 0–6; this audit retrained the incompatible local model, ran RL fine-tuning, and completed the full 2,000-seed comparison required by Milestones 5–7. Completion means the training/evaluation workflow and its acceptance checks are implemented; it does not promise that RL improves the policy.

For repeated lesson collection, imitation retraining and resumable RL sessions, follow [the training workflow](training_workflow.md).

## Protocol and selection

Each policy played all seeds `3000000..3001999` to Game Over under the normal board-dependent dealer. Score is placed tile area; line clears earn no direct reward. The report contains per-seed results, distributions of score and game length (successful placements), and every paired score comparison. Confidence intervals use the repository's normal approximation.

The feature-version-2 imitation model used 15 complete improved training lessons, 20 epochs, learning rate 0.1, and random seed 17 (30,580 example presentations). Five lessons outside the training seed split were excluded. The older local feature-version-1 model was preserved.

REINFORCE initialized from imitation and trained for 10 full episodes on `1000000..1000009`, random seed 17, learning rate 0.0001, temperature 1, rolling-baseline decay 0.9. The initial and step-10 checkpoints were compared on the first 20 tuning seeds only. Their means were 302.40 and 277.45, so `selected.json` retained the step-0 imitation policy. The step-10 RL policy is reported separately; held-out results did not change selection.

## Held-out results

| Policy | Mean score | 95% CI for mean | Median | SD | P10 / P90 | Min / max | Mean placements |
|---|---:|---|---:|---:|---|---|---:|
| `first_fit` | 144.07 | 142.10 to 146.05 | 136 | 45.00 | 94 / 204 | 53 / 417 | 37.66 |
| `last_fit` | 143.18 | 141.22 to 145.13 | 136 | 44.61 | 93 / 203 | 53 / 383 | 37.43 |
| `random_fit` | 72.62 | 71.86 to 73.39 | 70 | 17.53 | 54 / 95 | 38 / 172 | 19.35 |
| `shanko` | 126.81 | 124.84 to 128.79 | 118 | 45.07 | 78 / 185 | 42 / 390 | 33.36 |
| `jc` | 176.58 | 174.03 to 179.14 | 164 | 58.37 | 117 / 253 | 78 / 488 | 46.18 |
| `sam` | 282.61 | 277.03 to 288.18 | 252 | 127.14 | 155 / 456 | 87 / 1150 | 73.58 |
| `codex_1` | 266.65 | 261.91 to 271.39 | 246 | 108.19 | 149 / 410 | 88 / 788 | 69.47 |
| `codex_sam` | 328.57 | 321.73 to 335.42 | 296 | 156.23 | 171 / 520 | 77 / 1210 | 85.41 |
| selected imitation (`learned`) | 339.25 | 331.60 to 346.90 | 299 | 174.55 | 168 / 563 | 65 / 1973 | 88.18 |
| RL step 10 | 337.14 | 329.58 to 344.71 | 297 | 172.59 | 168 / 558 | 65 / 1973 | 87.63 |

The strongest heuristic by held-out mean was `codex_sam`. Selected imitation minus `codex_sam`: +10.67 (95% CI +1.01 to +20.34); 978 wins, 127 ties, 895 losses. RL minus imitation: -2.10 (95% CI -5.60 to +1.40); 132 wins, 1706 ties, 162 losses.

The earlier pilot had already exposed the first 100 held-out seeds. As an additional check, the remaining 1,900 seeds (`3000100..3001999`) give selected imitation minus the same heuristic: +8.60 (95% CI -1.37 to +18.57); 927 wins, 118 ties, 855 losses. This subset was not used to choose the models or training settings.

Learned mode remains opt-in and Codex Sam remains the default. The full-sample gain is modest, and the interval on the 1,900 seeds beyond the earlier pilot includes zero, so these results do not establish a repeatable improvement on fresh seeds. The local selected model is available for explicit use; a clean checkout does not require training artifacts. A ten-episode RL run and 15 imitation lessons are a small experiment, not evidence that further training cannot help.

## Game-length distributions

Game length counts successful placements, not elapsed time.

| Policy | Mean placements | Median | P10 / P90 | Min / max |
|---|---:|---:|---|---|
| `first_fit` | 37.66 | 35 | 23 / 55 | 11 / 119 |
| `last_fit` | 37.43 | 35 | 23 / 53 | 11 / 101 |
| `random_fit` | 19.35 | 19 | 14 / 26 | 8 / 47 |
| `shanko` | 33.36 | 32 | 20 / 50 | 11 / 101 |
| `jc` | 46.18 | 43 | 29 / 67 | 17 / 130 |
| `sam` | 73.58 | 65 | 38 / 119 | 20 / 304 |
| `codex_1` | 69.47 | 65 | 38 / 107 | 20 / 212 |
| `codex_sam` | 85.41 | 77 | 44 / 137 | 17 / 332 |
| `learned` | 88.18 | 77 | 41 / 149 | 14 / 524 |
| `reinforcement` | 87.63 | 77 | 41 / 148 | 14 / 524 |

## Reproduce and inspect

Generated models, lessons, checkpoints and full JSON reports remain ignored under `learning_data/`. The exact existing lesson collection is required to reproduce these weights; a clean checkout can generate a new dataset with `collect-training`, but should not expect identical results from different lessons.

```sh
bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data --seed 17 --epochs 20 --output learning_data/models/imitation-v2.json
bundle exec ruby scripts/learn.rb train-rl --model learning_data/models/imitation-v2.json --episodes 10 --seed 17 --learning-rate 0.0001 > learning_data/rl-training-v2.json
RL_CHECKPOINT=$(ruby -rjson -e 'puts JSON.parse(File.read("learning_data/rl-training-v2.json")).fetch("checkpoints").last.fetch("path")')
bundle exec ruby scripts/benchmark.rb --seed-set held_out --workers 4 --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned --model learning_data/checkpoints/selected.json --comparison-model "reinforcement=$RL_CHECKPOINT" --output learning_data/held-out-2000-v2.json
./1010 auto learned --model learning_data/checkpoints/selected.json --seed 42
./1010 auto codex_sam --seed 42
```

The training command above retains its JSON summary. Resume from the step-10 checkpoint with `train-rl --resume PATH --episodes 10 --seed 17 --learning-rate 0.0001`; resuming the selected step-0 pointer would instead restart at step 0. The existing `select --checkpoint PATH` command deliberately overrides selection after tuning evaluation.

Four workers preserve seed order and evaluation results. Serial evaluation remains the default; process parallelism requires `Process.fork` (macOS/Linux). Workers retain only metric summaries, keeping full trajectories out of benchmark memory.

Full local report: `learning_data/held-out-2000-v2.json`. Training summary: `learning_data/rl-training-v2.json`. Selected pointer: `learning_data/checkpoints/selected.json`.

| Provenance | Value |
|---|---|
| Source revision | `8bfb58d49523f18d805d170f1e1603aa227df804` (revision recorded at report completion; working tree marked dirty) |
| Source SHA-256 | `056489be4602f524710a6c497e41d2a600a24e94344788cfaeee7eeb1723948e` |
| Resolved model SHA-256: learned | `3821ac4880a7a150aa439e1be5639fb797c1b95820b15d9d7278b8a5b1409cf1` |
| Resolved model SHA-256: reinforcement | `70a1c8ca635d54b9a276c8b44ecb9d11909b773e4fd4b6bc8ab792ec56755785` |

## Larger experiment: 343 lessons, 200 RL episodes

`scripts/phase6_evaluation.sh` repeated the protocol with more training data. It
ran from `d94c0af` with a clean tree, Ruby 4.0.7 and 11 evaluation workers. Its
source fingerprint is the same as above (`056489be…`), so the code is identical.

- **Lessons:** 343 complete improved lessons from training seeds
  `1000000..1000399`. A second machine collected the same seeds and scores.
- **Imitation:** seed 17, 20 epochs, learning rate 0.1. That is 773,440 example
  presentations, 25 times the first experiment's. Model SHA-256 `4fef8aaf…`.
- **RL:** 200 REINFORCE episodes on `1000000..1000199`, with random seed 17,
  learning rate 0.0001, temperature 1 and baseline decay 0.9. A checkpoint every
  25 episodes was scored on tuning seeds `2000000..2000099`. Selection chose the
  step-25 checkpoint (tuning mean 342.95, 95% CI 306.71 to 379.19) over step 0.
  The resolved model SHA-256 is `9af8b3ef…`. The final step-200 checkpoint is
  `55ce952c…`.

All eight heuristics reproduced the first experiment's per-seed held-out scores
exactly. The heuristic table above therefore applies unchanged.

| Policy | Mean score | 95% CI for mean | Median | Mean placements |
|---|---:|---|---:|---:|
| `codex_sam` (default) | 328.57 | 321.72 to 335.42 | 296 | 85.41 |
| imitation, 343 lessons | 332.44 | 325.31 to 339.57 | 294 | 86.45 |
| RL step 25 (tuning-selected) | 335.87 | 328.75 to 343.00 | 296 | 87.36 |
| RL step 200 (final) | 336.96 | 329.78 to 344.14 | 299 | 87.64 |

| Paired difference | All 2,000 seeds | Seeds `3000100..3001999` |
|---|---|---|
| selected − `codex_sam` | +7.30 (−1.89 to +16.49); 943/149/908 | +5.33 (−4.13 to +14.80) |
| imitation − `codex_sam` | +3.86 (−5.37 to +13.10); 923/150/927 | +2.59 (−6.95 to +12.14) |
| RL step 200 − `codex_sam` | +8.39 (−0.78 to +17.55); 954/149/897 | +7.47 (−2.00 to +16.94) |
| selected − imitation | +3.44 (−1.34 to +8.21); 261/1508/231 | +2.74 (−2.09 to +7.57) |
| RL step 200 − imitation | +4.52 (−2.34 to +11.39); 603/844/553 | +4.87 (−2.14 to +11.88) |

Intervals are 95% normal-approximation CIs. The win/tie/loss counts are for the
first policy named.

**Conclusion.** No learned policy from this run beats `codex_sam` with an
interval above zero, on either seed range. Twenty-three times more lessons did
not raise the imitation model above the 15-lesson model's 339.25. RL now edges
imitation by a few points, but those intervals also include zero. Codex Sam
stays the default, and learned mode stays opt-in. Further gains probably need
changes to the features or the training method, not just more of the same data.
Held-out results were not used to choose any model or setting.

The models, checkpoints and full report are in the ignored
`learning_data/run-20261101/`. Rerun the experiment with
`scripts/phase6_evaluation.sh`; it collects its own lessons on a clean checkout.
See [the training workflow](training_workflow.md) for continued sessions and
model selection.

## Issue #33: stronger-teacher lessons — tuning-selected candidate

The next experiment changed the lesson baseline and rollout strategy to `codex_sam`. It used the same training seed range `1000000..1000399`, action features v2, imitation seed 17, 20 epochs and learning rate 0.1. Search limits were beam width 4, 2,000 states, 8 rollouts, 2 rollouts per step and a 30-second safety cap. Collection retained 304 complete improved lessons from 400 episodes; 96 found no improvement within the rollout budget and none was time-capped. Training used 793,420 example presentations, with no lesson exclusions.

All jobs ran detached on the designated compute machine. Source `d25a570` and the benchmark-source fingerprint `056489be4602f524710a6c497e41d2a600a24e94344788cfaeee7eeb1723948e` remained unchanged throughout collection, training, tuning and final evaluation. No heuristic or feature implementation changed.

On paired tuning seeds `2000000..2000499` (500), the new model averaged **379.972** versus Codex Sam's **322.932**: **+57.040 (95% CI +36.069 to +78.011)**, 286 wins/40 ties/174 losses. Against the previously selected model on the same seeds, the gain was +33.576 (95% CI +11.315 to +55.837). The tuning result was [posted on #33](https://github.com/shanko/1010/issues/33#issuecomment-6565072047) before any held-out evaluation began.

The qualifying model was frozen at resolved-model SHA-256 `9347eed45cb853de582b01b0e5a4664a4f387ddd6da4710bb23a71d6fa16e3e4`. The lesson manifest SHA-256 is `ca8bb2d90c4266e862f31c6bbfe806b6538e04fd2d00c367fcb6bb43615a401c`. No corrective-lesson, feature-v3 or longer-RL experiment was needed.

The model then received **one final held-out evaluation**, against all eight heuristics. Every heuristic per-seed summary reproduced the prior report exactly, so the heuristic table above remains applicable.

| Policy | Mean score | 95% CI for mean | Median | SD | P10 / P90 | Min / max |
|---|---:|---|---:|---:|---|---|
| Codex Sam | 328.573 | 321.726 to 335.419 | 296 | 156.227 | 171 / 520 | 77 / 1210 |
| Stronger-teacher imitation | 375.504 | 366.948 to 384.059 | 325 | 195.212 | 185 / 633 | 96 / 1581 |

| Paired candidate minus Codex Sam | Mean difference | 95% CI | Wins/ties/losses |
|---|---:|---|---|
| All 2,000 seeds (`3000000..3001999`) | +46.931 | +36.873 to +56.989 | 1095/140/765 |
| 1,900 seeds after the pilot (`3000100..3001999`) | +44.765 | +34.379 to +55.151 | 1034/137/729 |

The candidate's game length averaged 97.618 placements (95% CI 95.340 to 99.895), median 83, P10/P90 47/167, range 22–428. Codex Sam averaged 85.412 placements. Full score/game-length distributions and per-seed comparisons for all nine policies are in `learning_data/issue33/final/held-out.json`.

**Conclusion:** this candidate beats Codex Sam with a paired 95% interval above zero on both required ranges, after passing the tuning gate. The full-sample mean gain is about 14.3%. These seed ranges were used in earlier experiments; they are not a newly untouched test set. For #33, the candidate and settings were frozen before reading its held-out scores, and the result was not used to start further training.

**Default proposal for the maintainer:** the frozen model now meets #33's statistical criterion for considering learned mode as the default. Codex Sam remains the actual default until the maintainer approves a change and decides how to distribute/configure the model for clean checkouts. No model, checkpoint or lesson data is committed. The model is available locally and on the compute machine under the same repository-relative path.

Try the exact candidate:

```sh
./1010 auto learned --model learning_data/issue33/experiment1/models/imitation.json --seed 42
```

Reproduction settings, the experiment sequence, tuning-only decisions and audit counts are recorded in [the #33 experiment log](issue33_experiments.md). The candidate model is `learning_data/issue33/experiment1/models/imitation.json`; the training summary and tuning report are beside it. The final report and artifacts remain ignored.

## Verification

- Full Minitest suite: 159 tests, 911 assertions, no failures/errors/skips. RuboCop: 51 files, no offenses.
- Resumed RL training exactly matches an uninterrupted two-episode run.
- Serial and parallel benchmark reports have identical policy statistics and pairwise results.
- Missing-model tests use an empty temporary directory and pass with or without local trained models.
- All six strategies recorded in `benchmarks/baseline-v3.json` match their committed per-seed results on seeds 1–100 after the style-only lint fixes. The two newer Codex policies are covered by their deterministic gameplay tests.

## Approved promotion

After reviewing #33, the maintainer approved making this exact candidate the
default, named `learned`. The release model now ships at `models/learned.json`.
`./1010 auto` and `./1010 auto learned` use it without local training artifacts;
`--model PATH` overrides it. Codex Sam remains available explicitly.
The proposal and unchanged-default statements above describe the evaluation
before this approval. No additional held-out evaluation selected the release.

Promotion verification: 161 tests, 915 assertions, zero failures/errors/skips;
RuboCop passes. `benchmarks/baseline-v5.json` records the bundled policy on
baseline seeds 1–100 and preserves all eight heuristic per-seed results from
v4 exactly. The release model checksum matches the frozen #33 candidate.
