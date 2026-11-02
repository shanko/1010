# Baseline benchmark reports

`baseline-v1.json` records all existing auto-player strategies on the same 100
seeds (1 through 100). It includes the per-seed results, score and secondary
metric distributions, paired score differences against `first_fit`, and a
SHA-256 fingerprint of the simulation/rules/player source files.

Regenerate it with:

```sh
bundle exec ruby scripts/benchmark.rb --seeds 1..100 --output benchmarks/baseline-v1.json
```

Use a new filename for later benchmark versions so earlier comparisons remain
available.

`baseline-v2.json` records the same 100 seeds after the footprint scoring
change in #24. It preserves v1 for historical comparisons and is the parity
reference for subsequent behavior-preserving Phase 3 work.

`baseline-v3.json` records the same six strategies after Sam became the default
(#25); its per-seed results are identical to v2.

`baseline-v4.json` adds `codex_1` and `codex_sam`, so all eight heuristic
strategies are covered. The six earlier strategies match v2 and v3 seed for
seed. It is the current parity reference:

```sh
bundle exec ruby scripts/benchmark.rb --seeds 1..100 --workers 4 --output benchmarks/baseline-v4.json
```

| Strategy | Mean score, seeds 1–100 |
|---|---:|
| codex_sam | 346.10 |
| sam | 259.93 |
| codex_1 | 257.19 |
| jc | 171.94 |
| first_fit | 142.14 |
| last_fit | 137.29 |
| shanko | 123.28 |
| random_fit | 71.28 |

`baseline-v5.json` adds the maintainer-approved default `learned` policy,
using the bundled `models/learned.json` on the same 100 baseline seeds.
All eight heuristic results remain identical to v4. V4 remains the heuristic
parity reference; v5 also records the released learned policy.

```sh
bundle exec ruby scripts/benchmark.rb --seeds 1..100 --workers 4 --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned --model models/learned.json --output learning_data/release-parity.json
```

The committed v5 report uses repository-relative model paths to avoid publishing
machine-specific paths. Its source fingerprint and model checksum identify the
evaluated code and weights.

`baseline-v6.json` records the demonstration-guided wall calibration of
`learned`. All eight heuristic per-seed results still match v4 and v5 exactly.
The model hash identifies the new release; model paths are normalized to the
bundled path and its JSON file checksum reflects the packaged trailing newline.
Generation used the frozen candidate with the same command as v5, before
packaging (the source revision and source fingerprint record that checkout).
See [the best-score study](../docs/best_score_study.md) for independent tuning
confirmation and the one final evaluation on newly reserved test seeds.
