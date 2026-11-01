# Issue #33: tuning experiments

Issue #33 was the next unchecked item in roadmap #27. Experiments use training
and tuning seeds only; each tuning result is posted on #33 before the next
experiment starts. Long jobs run detached on the designated compute machine,
following `agent_instructions.md` section 8. Artifacts remain ignored under
`learning_data/issue33/`.

## Fixed comparison protocol

- Source at the start: `d25a570`.
- Paired tuning seeds: `2000000..2000499` (500 games per policy).
- Comparator: `codex_sam`; metric: final score at Game Over.
- Report the paired candidate-minus-comparator mean and normal-approximation
  95% confidence interval, plus score distributions and per-seed results.
- Training seeds for the first new lesson collection: `1000000..1000399`.
- Do not use held-out results for model/settings selection. A new candidate
  must clear the tuning gate before its one final held-out evaluation.
- `codex_sam` stays the default; any proposed change is the maintainer's decision.

## Experiment 0: reproduce the existing models

The two models are from the previously completed 343-lesson experiment.

| Policy | Tuning mean | Difference vs Codex Sam | 95% CI |
|---|---:|---:|---|
| Codex Sam | 322.932 | 0 | — |
| Prior selected RL step 25 | 346.396 | +23.464 | +4.208 to +42.720 |
| Prior imitation | 336.928 | +13.996 | -3.651 to +31.643 |

The prior selected checkpoint clears this tuning gate, but it is an already
evaluated model with a recorded held-out result, not a new candidate for #33.
No held-out run was repeated. The prior imitation interval includes zero.

Reproduce:

```sh
bundle exec ruby scripts/benchmark.rb --seeds 2000000..2000499 --workers 11 --strategies codex_sam --comparison-model prior_selected=learning_data/run-20261101/checkpoints/selected.json --comparison-model prior_imitation=learning_data/run-20261101/models/imitation.json --output learning_data/issue33/baseline.json
```

The result was posted before Experiment 1 started:
[#33 experiment-0 result](https://github.com/shanko/1010/issues/33#issuecomment-6564911553).

## Experiment 1: stronger-teacher lessons — tuning gate passed

Collect from the same 400 training seeds as the previous larger experiment,
using `codex_sam` as both baseline and search rollout strategy. Search limits:
beam width 4, 2,000 states, 8 rollouts, 2 rollouts per step, 30-second safety
cap. Eight independent batches collect 50 seeds each. A read-only audit hook
records search status, completeness and cap reason for every seed.

Collection completed on all 400 seeds: 304 complete improvements were saved,
96 found no improvement within budget, and zero searches were time-capped.
All searches stopped at the configured rollout limit.

The action-feature-version-2 imitation model used seed 17, 20 epochs and learning
rate 0.1: 304 episodes used, 793,420 example presentations, no exclusions.
Collection took 75 seconds, training 10 minutes 20 seconds, and tuning 29 seconds.

| Policy | Mean score | 95% CI for mean | Median | P10 / P90 |
|---|---:|---|---:|---|
| Codex Sam | 322.932 | 309.941 to 335.923 | 293 | 171 / 515 |
| Stronger-teacher imitation | 379.972 | 361.799 to 398.145 | 336 | 172 / 651 |

Paired candidate minus Codex Sam: **+57.040 (95% CI +36.069 to +78.011)**,
with 286 wins, 40 ties and 174 losses. The comparator's per-seed results exactly
match Experiment 0. Versus the prior selected model, the gain is +33.576
(95% CI +11.315 to +55.837).

The new model clears the tuning gate and improves on the prior selected
checkpoint on the same tuning seeds. No corrective-lesson, feature-v3 or
longer-RL experiment was started: the first idea supplied a qualifying candidate.
The result was posted before final held-out evaluation started:
[#33 experiment-1 result](https://github.com/shanko/1010/issues/33#issuecomment-6565072047).

Frozen resolved model SHA-256:
`9347eed45cb853de582b01b0e5a4664a4f387ddd6da4710bb23a71d6fa16e3e4`.
Lesson-manifest SHA-256:
`ca8bb2d90c4266e862f31c6bbfe806b6538e04fd2d00c367fcb6bb43615a401c`.
The retained lessons average 277.905 actual points and 502.993 candidate points;
these are conditional on being retained improvements, not all 400 source games.

Reproduce the eight collection batches, then train and evaluate on the compute
machine (the exact archived lesson filenames/order are required to reproduce
these weights):

```sh
(
  set -e
  experiment_dir=learning_data/issue33/reproduction-01
  test ! -e "$experiment_dir"
  mkdir -p "$experiment_dir/lessons" "$experiment_dir/models"
  pids=()
  for batch in 0 1 2 3 4 5 6 7; do
    first=$((1000000 + batch * 50))
    last=$((first + 49))
    bundle exec ruby scripts/learn.rb collect-training --strategy codex_sam --seeds "$first..$last" --max-states 2000 --max-rollouts 8 --beam-width 4 --rollouts-per-step 2 --budget 30 --output "$experiment_dir/lessons" > "$experiment_dir/collect-$batch.json" &
    pids+=("$!")
  done
  failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  test "$failed" -eq 0
  bundle exec ruby scripts/learn.rb train-imitation --lessons "$experiment_dir/lessons" --seed 17 --epochs 20 --learning-rate 0.1 --output "$experiment_dir/models/imitation.json"
  bundle exec ruby scripts/benchmark.rb --seeds 2000000..2000499 --workers 11 --strategies codex_sam --comparison-model "candidate=$experiment_dir/models/imitation.json" --output "$experiment_dir/tuning.json"
)

```

The command refuses to overwrite an existing experiment directory and checks
every collector exit status before training. Change the directory name for
later reruns. In the recorded experiment, a read-only audit hook also logged
each search result without changing search or lesson behavior.

## Final held-out evaluation (complete)

The frozen model was evaluated once against all eight heuristics on
`3000000..3001999`, with a separate paired summary for `3000100..3001999`.
These seed ranges were used in earlier experiments; they are not a newly
untouched test set. This issue uses them only after freezing its candidate,
and no results from this final evaluation were used to run another experiment.
The default stays Codex Sam; promotion is a proposal for the maintainer, not
an automatic change.

Result: 375.504 versus 328.573 on all 2,000 seeds; paired gain +46.931
(95% CI +36.873 to +56.989), with 1095 wins/140 ties/765 losses. On the
1,900 seeds after the old pilot, the gain is +44.765 (95% CI +34.379 to
+55.151), with 1034 wins/137 ties/729 losses. Both intervals are above zero.
All eight heuristic per-seed summaries exactly match the prior evaluation.
The frozen checksum was verified before and after the run, which completed
successfully in 152 seconds. See [the full result](learning_evaluation.md#issue-33-stronger-teacher-lessons--tuning-selected-candidate) for distributions
and the maintainer's default-strategy decision.

```sh
bundle exec ruby scripts/benchmark.rb --seed-set held_out --workers 11 --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned --model learning_data/issue33/experiment1/models/imitation.json --output learning_data/issue33/final/held-out.json
```

This is the recorded final command, not a request to rerun held-out evaluation
during future tuning. Later experiments need an evaluation protocol fixed
before inspecting their test results.

## Saved artifacts

Exact lesson files, models, search audit, runners and reports are preserved in
`learning_data/issue33/review-artifacts.tar.gz`, copied to local ignored data
and retained on the compute machine. Archive SHA-256:
`8d7b8c1999ddca7b7bbaad2415d4f34b327cbeb9210fd2fb9fae4d75f009dd11`.
Only documentation is committed. The full JSON reports include metric
distributions, per-seed scores, pairwise differences and source/model provenance.

## Verification

- `bundle exec rake test`: 159 tests, 911 assertions, no failures/errors/skips.
- `bundle exec rake lint`: 51 files, no offenses.
- All eight strategies match `benchmarks/baseline-v4.json` per seed on seeds
  1–100, using four benchmark workers.

Final results are recorded in [the evaluation report](learning_evaluation.md#issue-33-stronger-teacher-imitation). Both held-out intervals are above zero; making learned the default is proposed for the maintainer, with no automatic change.
