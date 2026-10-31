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
