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
