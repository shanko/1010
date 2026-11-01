#!/usr/bin/env bash
# Milestones 6-7 (roadmap #27, Phase 6): lessons -> imitation -> RL -> tuning selection
# -> 2,000-seed held-out benchmark of every heuristic and the learned models.
#
# Usage, from the repository root:
#   scripts/phase6_evaluation.sh [BUNDLE_DIR] [WORKERS]
#
# BUNDLE_DIR (optional) holds lessons/ and lessons.sha256 from an earlier collection;
# without it, lessons are collected from training seeds 1000000..1000399.
# WORKERS defaults to one less than the number of CPUs (held-out benchmark only;
# training is single-threaded). Outputs go to learning_data/run-20261101/ (ignored by Git).
# Each step is skipped when its output already exists, so an interrupted run can resume.
set -euo pipefail

BUNDLE=${1:-}
WORKERS=${2:-$(($(getconf _NPROCESSORS_ONLN) - 1))}
D=learning_data/run-20261101
LOG=$D/phase6.log
mkdir -p "$D"
exec > >(tee -a "$LOG") 2>&1
stamp() { echo "[$(date '+%F %T')] $*"; }

stamp "ruby: $(ruby -v)"
stamp "revision: $(git rev-parse HEAD)"
git diff --quiet 8bfb58d -- lib Gemfile Gemfile.lock scripts/*.rb ||
  { echo "lib/, scripts/*.rb or the Gemfile differ from 8bfb58d; results would not be comparable"; exit 1; }
[ -z "$(git status --porcelain -- lib scripts)" ] || { echo "uncommitted changes in lib/ or scripts/"; exit 1; }
bundle install --quiet

# 1. Lessons: complete improved lessons from training seeds only.
if [ ! -d "$D/lessons" ]; then
  mkdir -p "$D/lessons"
  if [ -n "$BUNDLE" ]; then
    cp "$BUNDLE"/lessons/*.json "$D/lessons/"
  else
    stamp "collect-training start"
    pids=()
    for i in 0 1 2 3; do
      start=$((1000000 + i * 100))
      bundle exec ruby scripts/learn.rb collect-training --seeds "$start..$((start + 99))" \
        --output "$D/lessons" > "$D/collect-$i.json" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
  fi
fi
if [ -n "$BUNDLE" ]; then
  (cd "$D/lessons" && shasum -a 256 -c "$BUNDLE/lessons.sha256" --quiet) || { echo "lesson checksum mismatch"; exit 1; }
fi
stamp "lessons: $(find "$D/lessons" -name '*.json' | wc -l | tr -d ' ')"

# 2. Imitation, with the settings of the 2968bfa audit. About 85 CPU-minutes for 343 lessons
#    on an M-series MacBook Pro.
if [ ! -f "$D/models/imitation.json" ]; then
  stamp "train-imitation start"
  bundle exec ruby scripts/learn.rb train-imitation --lessons "$D/lessons" --seed 17 --epochs 20 \
    --learning-rate 0.1 --output "$D/models/imitation.json" > "$D/imitation-training.json"
fi
stamp "imitation sha256: $(shasum -a 256 "$D/models/imitation.json" | cut -d' ' -f1)"

# 3. REINFORCE from the imitation model on training seeds. Checkpoints every 25 episodes are
#    scored on tuning seeds 2000000..2000099; the best one (step 0 included) is selected.
if [ ! -f "$D/rl-training.json" ]; then
  stamp "train-rl start"
  bundle exec ruby scripts/learn.rb train-rl --model "$D/models/imitation.json" --episodes 200 --seed 17 \
    --learning-rate 0.0001 --temperature 1 --baseline-decay 0.9 --checkpoint-interval 25 \
    --tuning-seeds 2000000..2000099 --checkpoints "$D/checkpoints" > "$D/rl-training.json"
fi
RL_FINAL=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("checkpoints").last.fetch("path")' \
  "$D/rl-training.json")
stamp "selected pointer: $(cat "$D/checkpoints/selected.json")"
stamp "final RL checkpoint: $RL_FINAL"

# 4. Held-out seeds 3000000..3001999: every heuristic, the tuning-selected policy (learned), the
#    imitation-only model and the final RL checkpoint. Held-out results never change selection.
if [ ! -f "$D/held-out-2000.json" ]; then
  stamp "held-out benchmark start ($WORKERS workers)"
  bundle exec ruby scripts/benchmark.rb --seed-set held_out --workers "$WORKERS" \
    --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned \
    --model "$D/checkpoints/selected.json" \
    --comparison-model "imitation=$D/models/imitation.json" \
    --comparison-model "reinforcement=$RL_FINAL" \
    --output "$D/held-out-2000.json"
fi

# 5. Pack the results.
tar -czf "$D/phase6-results.tar.gz" -C "$D" models checkpoints imitation-training.json rl-training.json \
  held-out-2000.json phase6.log
stamp "done: $D/phase6-results.tar.gz"
