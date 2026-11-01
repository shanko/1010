# Full-game learning evaluation — November 1, 2026

## Milestone audit

Milestones 0–5 are implemented. Milestone 6's REINFORCE training, checkpointing,
resumption and tuning-based selection are implemented and tested. Its final
held-out comparison, together with Milestone 7's full 2,000-seed comparison,
is running. Final results will be recorded in a separate commit.

The initial suite passed with 155 tests and 894 assertions. The expanded suite
passes with 159 tests and 909 assertions; RuboCop reports no offenses in 50
files. New checks cover exact equivalence of resumed and uninterrupted RL
training, serial/parallel benchmark parity, named model comparisons, and worker
failure without a partial report. Missing-model tests now run in an empty
temporary directory so local training artifacts cannot affect them.

All six strategies in `benchmarks/baseline-v3.json` reproduce their committed
per-seed results on seeds 1–100 after the style-only lint fixes.

## Training and selection completed

The previous local imitation model used feature version 1, which the current
feature-version-2 implementation correctly rejects. It was preserved, and a
new model was trained from 15 valid improved training lessons with seed 17,
20 epochs and learning rate 0.1 (30,580 example presentations). Five lessons
outside the training seed split were excluded.

REINFORCE initialized from that model and trained for 10 full episodes on
`1000000..1000009`, random seed 17, learning rate 0.0001, temperature 1 and
rolling-baseline decay 0.9. On the first 20 tuning seeds, the initial model
averaged 302.40 and the step-10 checkpoint averaged 277.45. Selection retained
the initial imitation policy. Its weights were verified to match the imitation
model exactly. Both checkpoints remain available locally.

## Evaluation in progress

All eight heuristics, the tuning-selected imitation policy (`learned`) and the
step-10 RL policy (`reinforcement`) are playing seeds `3000000..3001999` to
Game Over under the normal board-dependent dealer. Held-out results will not
change model selection. The report will include per-seed results, score and
placement-count distributions, normal-approximation 95% confidence intervals,
and every paired score comparison. Because the earlier pilot already exposed
the first 100 seeds, the remaining 1,900 seeds will also be reported separately.

The benchmark now supports `--comparison-model NAME=PATH` and `--workers 4`.
Parallel evaluation preserves serial seed order and results, requires
`Process.fork` (macOS/Linux), and retains metric summaries instead of full move
histories. One process remains the default.

Models, lessons, checkpoints and full reports remain ignored in
`learning_data/`. The exact lesson collection is needed to reproduce these
weights; a clean checkout can generate new lessons with `collect-training`.

```sh
bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data --seed 17 --epochs 20 --output learning_data/models/imitation-v2.json
bundle exec ruby scripts/learn.rb train-rl --model learning_data/models/imitation-v2.json --episodes 10 --seed 17 --learning-rate 0.0001 > learning_data/rl-training-v2.json
RL_CHECKPOINT=$(ruby -rjson -e 'puts JSON.parse(File.read("learning_data/rl-training-v2.json")).fetch("checkpoints").last.fetch("path")')
bundle exec ruby scripts/benchmark.rb --seed-set held_out --workers 4 --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned --model learning_data/checkpoints/selected.json --comparison-model "reinforcement=$RL_CHECKPOINT" --output learning_data/held-out-2000-v2.json
```

Resume the trained RL checkpoint with `train-rl --resume PATH --episodes 10
--seed 17 --learning-rate 0.0001`. Resuming the selected step-0 pointer would
instead restart at step 0. `select --checkpoint PATH` deliberately overrides
selection after tuning evaluation. Learned mode remains opt-in; run it with
`./1010 auto learned --model learning_data/checkpoints/selected.json --seed 42`
or use the default heuristic (Codex Sam) with `./1010 auto --seed 42`.
