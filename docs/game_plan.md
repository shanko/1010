# Full-game learning plan for 1010!

## Goal

Improve the auto-player's average final score by learning from complete games, from a fresh board until Game Over. A placement earns one point per tile square. Clearing a row or column earns no immediate points, but can make later placements possible, so final game score already rewards useful clears indirectly.

The system must support two learning signals:

1. **Imitation learning:** a search procedure finds an improved continuation and supplies action examples for the auto-player to imitate.
2. **Reinforcement learning:** the auto-player plays complete simulated games and adjusts its policy to maximize final score.

Do not describe the optimizer's best result as a proven maximum unless it exhaustively searched the relevant decision space or otherwise proved an upper bound. The first optimizer is an anytime improvement finder: keep the best candidate found so far, stop at its compute budget, and report whether it found an improvement.

## Current code map and constraints

- `board.rb` contains the rules, tile options, placement legality, score, line clearing, and deal generation. `Board1010#play` adds the tile's square count to the score.
- `auto_player.rb` contains simple current strategies (`first_fit`, `last_fit`, `random_fit`, `shanko`, `jc`, `sam`). `choose_move` currently selects a fitting option randomly before selecting a location.
- `game_1010.rb` runs the graphical loop and records a seed plus move/undo records.
- `game_log.rb` writes versioned `.moves` traces with the starting board, mode, exact offers, move identities, undos, and final score; `game_trace.rb` validates and replays v2 traces headlessly.
- `game_simulator.rb` runs full headless episodes; `scripts/benchmark.rb` evaluates strategies on paired seeds and reports score and secondary-metric distributions.
- `improvement_search.rb` runs bounded beam search with strategy rollouts, seeded normal-deal search, and frozen-offer counterfactual search.
- `learned_player.rb` defines versioned action features, a Ruby-native linear scorer, and deterministic imitation training; `policy_corrector.rb` searches continuations from states visited by a learned policy.
- `reinforcement_trainer.rb` runs REINFORCE episodes with a rolling return baseline and writes versioned checkpoints plus a tuning-selected pointer.
- `learning_seed_sets.rb` defines disjoint baseline, training, tuning, and held-out seed lists.
- `terminal_game.rb` is a second human-play path and also creates game logs.
- `test/` contains Minitest coverage; run the full suite with `bundle exec rake test`.

Important rules for the implementation:

- The board is 10x10 and the game has 19 fixed tile shapes.
- An episode ends when none of the current options fit. The option dealer may replace the first random tile with a small fitting tile when none of the random options fit. That fallback depends on the board, so alternate action sequences can receive different effective options even with the same seed.
- `Board1010#copy` snapshots random state independently. Preserve that branch isolation and test it whenever simulator or search state cloning changes.
- Existing `.moves` files or saved games may not contain enough information to reconstruct their initial state or offers. Preserve compatibility where practical and report unsupported/incomplete data clearly.
- Existing cell values and tile type IDs support rendering colors; score and legality must remain based on tile area and occupancy, not tile color.

## Milestone 0: establish and document the objective

**Status: complete**

### Work

1. Define the primary metric as final score at Game Over. Define operational secondary metrics for retained placed tiles, total cleared row/column events, batches offered, and score distribution across seeds.
3. Verify the invariant that the score for a run equals the sum of the areas of all successfully placed tiles. Do not add direct score for clearing lines unless the game rules are deliberately changed.
4. Define a fair comparison protocol: run policies on the same list of seeds, but let each policy's board state drive the existing board-dependent offer fallback.
5. Keep “same fixed observed offers” as a separate counterfactual analysis mode. In that mode, freeze the exact offers from the logged episode; label it clearly because it is not the same as playing the normal seeded environment after the board diverges.
6. Store the definitions and comparison protocol in `docs/learning_objective.md` and keep that document aligned with the simulator and reports.

### Acceptance criteria

- Tests establish score equals the sum of placed tile areas, including placements that clear rows and columns.
- README or learning documentation explains why line clears affect later score rather than scoring immediately.
- `docs/learning_objective.md` defines the primary/secondary metrics and the paired-seed and fixed-offer comparison modes.

## Milestone 1: capture replayable, versioned game episodes

**Status: complete**

### Work

1. Extend the game log format with a version marker and explicit episode metadata: seed, starting board/save snapshot where applicable, game mode, and the existing move/undo events.
2. Record each actual option batch in order using stable tile names from `Board1010::TILES` (or stable IDs with a documented mapping). Record when a batch is offered, not just which option is selected.
3. Capture accepted moves with option identity, anchor row/column, and enough information to distinguish the actual offered tile after any fallback. Preserve undo events and their order.
4. Ensure a fresh seeded game can be reconstructed exactly from a trace. For loaded saves or seedless sessions, include the initial board and the random/deal state needed for later draws, or mark the trace as non-counterfactual/replayable with a clear reason.
5. Make dealing and RNG advancement branch-safe. Prefer an explicit deterministic deal stream or clonable RNG snapshots. Prove that two simulations starting from the same state and random state produce the same offers, independent of execution order.
6. Keep current logs readable where possible; add a parser for earlier versions and return a useful compatibility error for data that cannot be replayed faithfully.

### Acceptance criteria

- A log of a seeded human or auto game reconstructs the same offers, accepted moves, undos, and final score.
- A test records an episode, replays it headlessly, and compares its final board, score, and offer history.
- Two cloned search branches do not mutate one another's board or random state.
- Invalid, truncated, old, or incomplete traces fail with an actionable diagnostic rather than a misleading replay.

## Milestone 2: create a headless full-game simulator and benchmark

**Status: complete**

### Work

1. Add a simulator that runs `Board1010` and an `AutoPlayer` without Gosu or sleeps.
2. Give it explicit inputs for seed, policy, and optional trace capture. It should run until the same Game Over condition used by the graphical game.
3. Add a batch runner for a fixed seed list. Report mean, median, standard deviation, minimum, maximum, and selected percentiles for final score and game length.
4. Benchmark every existing strategy and save the baseline results with code version, strategy name, seeds, and simulator version.
5. Use separate training, tuning, and held-out evaluation seed lists. Do not select a policy based on its held-out results.

### Acceptance criteria

- Headless simulation returns the same score as replaying a captured auto game.
- Same seed and policy produce the same run on repeated executions.
- Batch results are reproducible and include all seed IDs.
- Existing gameplay behavior and the full test suite remain intact.

## Milestone 3: implement an anytime search for better complete games

**Status: complete**

### Work

1. Define an action as `(option_index, row, column)` and enumerate only legal actions.
2. Build a search interface that accepts a complete simulator state, an RNG/deal state, and a compute budget, then returns the best complete or partial trajectory found so far.
3. Start with an anytime beam search or Monte Carlo tree search over legal moves. Use fast rollouts with existing strategies to estimate long-term score. Keep search time and memory bounded by explicit configuration.
4. Preserve the current deal and fallback rules for normal seeded evaluation. Offer a separate frozen-offer mode for comparing alternatives against one historical sequence.
5. Add transposition detection using a canonical state key containing board occupancy, current option identities/order, score or accumulated reward, episode/deal position, and random/deal state. Ignore color metadata in legality keys unless it affects the rules.
6. Add safe pruning and deduplication only when they preserve the action space. Treat geometric symmetry reduction as optional and test tile orientation transforms before using it.
7. Return structured results: baseline score, best score found, score delta, elapsed time, explored states, candidate move sequence, and status (`improved`, `no improvement found within budget`, or `budget exhausted`). Do not claim `optimal` without proof.
8. Allow search to start from a captured initial state or a specified decision point. For a full-game comparison, search from the beginning so it can measure the whole trajectory.

The current API is `ImprovementSearch.search` in `improvement_search.rb`. Its `time_budget_seconds`, `beam_width`, and `max_states` bound search expansion and frontier memory. Seeded mode runs the baseline simulator first, then searches from the exact initial board and RNG state. Frozen-offer mode accepts named offer batches and reports `complete: false` when a candidate reaches the end of the supplied offers; this is a counterfactual horizon, not necessarily Game Over. The result status never claims optimality.

### Acceptance criteria

- On a small handcrafted state with a tractable action tree, search matches a brute-force test oracle.
- An anytime search always returns its best-so-far result when interrupted at its budget.
- Every returned action is legal when replayed from the recorded initial state.
- Search score equals the simulator's score for the returned sequence.
- Search does not mutate the source board, its options, or its random/deal state.
- `test/improvement_search_test.rb` checks a tractable frozen-offer board against a brute-force oracle, verifies legal candidate replay and source-state isolation, and checks the zero-budget best-so-far result.

## Milestone 4: persist and inspect learning lessons

**Status: complete**

### Work

1. Define a versioned lesson record containing: source episode/seed, initial state or decision state, actual action sequence and score, improved candidate sequence and score, improvement delta, search budget/status, and the exact offers or deal-stream state needed to reproduce the comparison.
2. Store lessons as local training data in a dedicated ignored directory (for example `learning_data/`), not in Git game-log history. Keep a small schema/example fixture tracked for tests.
3. Add a CLI command to analyze a `.moves` episode, run improvement search, save the lesson, and print the score comparison and first action divergence.
4. Make analysis read-only with respect to the source `.moves` file.
5. Deduplicate identical states and retain provenance so later training can exclude low-confidence or incomplete search results.

The command is `bundle exec ruby scripts/learn.rb analyze GAME.moves`. It accepts `--budget`, `--beam-width`, `--max-states`, `--strategy`, and `--output`. The default `learning_data/` directory is ignored by Git; the schema example in `test/fixtures/lesson-v1.json` is tracked. Only completed v2 traces are accepted. Lesson records preserve exact initial board, active offer history, actual and candidate sequences/scores, search limits and outcome. Search status and candidate completeness remain explicit so incomplete best-found results can be filtered during training.

### Acceptance criteria

- An analyzed episode can be reopened and both actual and candidate sequences replay to their recorded scores.
- A lesson with no improvement is not mislabeled as a successful expert example.
- Older/unreplayable logs are rejected with an explanation of missing fields.
- `test/lesson_store_test.rb` covers fixture replay, source immutability, deduplication/provenance, CLI output, and rejection of non-Game-Over traces.

## Milestone 5: train an imitation-learning policy from search examples

**Status: complete**

### Work

1. Add a policy interface that scores all legal `(option, row, column)` actions and chooses the highest-scoring action, with seeded random tie-breaking where needed.
2. Start with a small, interpretable feature set computed from the board before/after a candidate move. Include features such as tile area/type, rows and columns completed, remaining legal placements for current options, empty-region sizes, isolated empty cells, board-edge/neighbor structure, and resulting board occupancy. Document and unit-test every feature.
3. Turn high-quality search trajectories into state/action examples. Weight examples by search confidence and score improvement; exclude “best found” claims if the search result failed validation.
4. Train a simple Ruby-native action ranker/classifier first (for example, a linear scorer trained with pairwise ranking or multiclass updates). Keep feature extraction and model serialization versioned. Avoid adding a large ML dependency until a benchmark demonstrates the need.
5. Include states visited by the learned policy and ask the searcher for corrections where possible. This reduces the mismatch between states in the demonstrations and states encountered by the learned player.
6. Add a `learned` strategy name and a model-loading option. If no model exists, fail clearly or fall back only when explicitly requested.

Feature version 1 includes normalized tile area, one-hot tile type, cleared rows and columns, remaining legal placements in the current offer, largest four-neighbor empty component, empty-component count, isolated empty cells under eight-neighbor adjacency, anchor neighbors, touched edges, and resulting occupancy. The linear scorer uses a softmax imitation update on complete improved lessons, weighted by score delta. Training only accepts lessons from the training seed range and excludes non-improvements, incomplete candidates, invalid replays, and held-out episodes. `scripts/learn.rb correct` captures decision states visited by the learned policy and asks the bounded searcher for better continuations using training seeds. `scripts/benchmark.rb` can load a learned model and reports per-seed results and 95% mean confidence intervals.

### Acceptance criteria

- Training is deterministic for a fixed dataset and training seed.
- The saved model can be loaded in a fresh process and ranks legal actions consistently.
- Imitation policy is evaluated against all current strategies on held-out seeds, with reports including uncertainty and per-seed scores.
- Model training never reads the held-out evaluation results.
- `test/learned_player_test.rb` checks feature schema and values, legality, model loading, deterministic training, held-out exclusion, and learned-policy benchmark integration.

## Milestone 6: fine-tune the policy with reinforcement learning

**Status: complete**

### Work

1. Use the same legal-action interface and feature-based policy as imitation learning.
2. Treat one complete game as an episode. Reward each accepted placement by the tile's square count; final return then equals the game's score. Clearing lines affects future rewards through the resulting board, without inventing a direct clear bonus.
3. Initialize from the imitation model and train with a policy-gradient method with a baseline (such as REINFORCE with a learned/rolling value baseline), or another documented on-policy method suitable for the discrete legal-action set.
4. Keep exploration explicit and configurable. Use independent training seeds and deterministic evaluation seeds.
5. Save checkpoints with policy parameters, optimizer state, training step, seeds, feature/schema version, and training/evaluation summaries.
6. Retain the best checkpoint according to tuning-set performance, not training reward. Never overwrite the only prior model; write versioned checkpoints and an explicit selected-model pointer.

Run `bundle exec ruby scripts/learn.rb train-rl --model MODEL`. The trainer uses area-per-placement reward and an undiscounted return, with explicit softmax exploration temperature and a rolling baseline per decision index. It checks tuning seeds at checkpoint boundaries, keeps every checkpoint, resumes policy/baseline/step state, and atomically updates `selected.json` only when selecting the best tuning mean. The SGD optimizer is stateless and recorded as such.

### Acceptance criteria

- A tiny deterministic board/task demonstrates that the RL update moves action preference toward higher return.
- Training can resume from a checkpoint and produces reproducible results for fixed settings.
- The RL model is compared against the imitation-only model and existing heuristics on held-out seeds.
- Reports show average and distribution of scores, not only the single best game.
- `test/reinforcement_trainer_test.rb` checks preference updates from positive return, deterministic fixed-seed training, tuning-based selection, checkpoint retention/resume, and seed-split guards.

## Milestone 7: integrate, compare, and document the learned auto mode

**Status: implementation complete; 100-seed held-out pilot complete; full 2,000-seed evaluation remains**

### Work

1. Integrate the selected model with auto mode while keeping existing strategies available as baselines.
2. Add commands for headless evaluation, episode analysis, imitation training, RL training, and model selection. Keep training out of the graphical update loop.
3. Optionally display the current policy/model name and score in the window; do not add search or training latency to interactive frame updates.
4. Add a comparison report that runs all policies on identical evaluation seeds and presents score distributions, game lengths, and paired score differences.
5. Document how to reproduce a result, train from lessons, resume training, select a model, and revert to a heuristic.
6. Keep logs, lessons, and trained models ignored by Git unless the user explicitly chooses to share a small model or fixture.

Graphical auto mode accepts `learned` plus `--model PATH` (or defaults to `learning_data/checkpoints/selected.json`). The GUI loads the model once before play and keeps the existing heuristic strategies as the default. `scripts/benchmark.rb` produces paired per-seed comparisons, score distributions, confidence intervals, the strongest heuristic by mean, and learned-vs-strongest deltas. `scripts/learn.rb select` evaluates a retained checkpoint on tuning seeds before writing a selected pointer. A meaningful full held-out comparison requires collecting improved lessons and training a model; learned remains opt-in and JC remains the default until the comparison shows repeatable improvement.

`scripts/learn.rb collect-training --seeds START..END` fills the training data gap by simulating training-range episodes, running full seeded improvement searches with replayable candidate offer histories, and saving only complete, improved lessons after both paths validate. `LessonStore` retains separate actual/candidate offer streams so each normal seeded trajectory replays against the board-dependent dealer results it actually received. A pilot on the first 100 held-out seeds using 15 generated lessons yielded mean score 243.89 for the learned model and 207.87 for Sam; the paired mean difference was +36.02 (95% normal-approximation CI +11.36 to +60.68). The pilot report and generated model are in ignored local learning data; do not treat the pilot as the final 2,000-seed result.

### Acceptance criteria

- Learned auto mode runs a complete game to Game Over using the same board rules as the human game.
- A clean checkout can run tests without local model/training data present.
- The learned policy's held-out mean score is compared to the strongest existing baseline with a sufficiently large seed set and uncertainty intervals. If it does not improve, report that honestly and preserve the best-performing baseline as default.
- Full test suite passes with `bundle exec rake test`; all new algorithms have deterministic unit tests and end-to-end seeded simulation tests.

## Recommended Ruby components and command contract

Keep simulation, search, and training independent of Gosu so all long-running work can run in batch mode.

- `game_simulator.rb`: run one seeded episode and return a result object plus optional trace.
- `game_trace.rb`: versioned trace parsing/writing, state snapshots, offer batches, moves, undos, and final result.
- `improvement_search.rb`: bounded search and candidate sequence validation.
- `lesson_store.rb`: validate, append, query, and version lessons under `learning_data/`.
- `lesson_collector.rb`: generate and validate full-game training lessons from disjoint training seeds.
- `learned_player.rb`: legal-action scoring, model load/save, imitation training, and RL updates.
- `scripts/learn.rb`: command-line entry point for offline analysis, search, evaluation, and training.
- `scripts/benchmark.rb`: paired-seed strategy evaluation and learned-model reports.
- Add focused tests under `test/` for each component; do not require GUI initialization in those tests.

Use a consistent CLI contract (exact flags can follow existing Ruby style, but keep these operations available):

```sh
bundle exec ruby scripts/learn.rb analyze logs/<game>.moves --budget-seconds 10
bundle exec ruby scripts/learn.rb evaluate --strategies first_fit,jc,sam,learned --seeds-file seeds.txt
bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data/lessons.jsonl --output models/imitation.json
bundle exec ruby scripts/learn.rb train-rl --model models/imitation.json --steps 100000 --output-dir models/rl
bundle exec ruby game_1010.rb auto learned --model models/rl/best.json --seed 42
```

Learning artifacts should be self-describing and versioned. A trace needs a header (schema version, seed or initial state, rule version), ordered offer/deal records, accepted actions and undos, and an ending score. A lesson needs a reference to its source trace, the actual score/path, the candidate score/path, search budget and status, and the source/training schema versions. Reject mismatched versions instead of silently training on misread data.

## Suggested implementation order

Complete milestones in order. Do not begin model training until episode replay and headless evaluation are trustworthy. Do not make the learned policy the default until held-out evaluation shows a repeatable improvement. The first useful deliverable is milestones 1–3: reliable data, reproducible simulation, and an anytime search that can identify and replay a better full-game sequence.
