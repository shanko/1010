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

The larger experiment in [`scripts/phase6_evaluation.sh`](../scripts/phase6_evaluation.sh) collects lessons on training seeds `1000000..1000399`, trains imitation, then runs 200 RL episodes with 100 tuning seeds. It can also consume an existing lesson bundle. That separate experiment has no local completed results in this report; the results above describe the 15-lesson, 10-episode experiment. See [the training workflow](training_workflow.md) for continued sessions and model selection.

The benchmark was started before the later default-strategy update was integrated. The source revision/fingerprint fields were captured at report completion, rather than as a launch-time snapshot. Inspection of the intervening benchmark-source changes shows only default-strategy selection changes; all policies in this experiment were passed explicitly. The source hash is therefore completion-time provenance, not a claim that those exact on-disk files were loaded at launch.

## Verification

- Full Minitest suite: 159 tests, 911 assertions, no failures/errors/skips. RuboCop: 50 files, no offenses.
- Resumed RL training exactly matches an uninterrupted two-episode run.
- Serial and parallel benchmark reports have identical policy statistics and pairwise results.
- Missing-model tests use an empty temporary directory and pass with or without local trained models.
- All six strategies recorded in `benchmarks/baseline-v3.json` match their committed per-seed results on seeds 1–100 after the style-only lint fixes. The two newer Codex policies are covered by their deterministic gameplay tests.
