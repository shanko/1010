# Released learned policy

`learned.json` is the maintainer-approved default model, named `learned`.
It is the exact feature-v2 stronger-teacher imitation candidate evaluated for
issue #33, with 304 lessons, random seed 17, 20 epochs and learning rate 0.1.

Resolved model SHA-256 (Ruby `JSON.generate(LearnedPlayer.load(path).model)`):
`9347eed45cb853de582b01b0e5a4664a4f387ddd6da4710bb23a71d6fa16e3e4`.

On the fixed 2,000-seed evaluation set it gained 46.931 points over Codex Sam
(95% CI +36.873 to +56.989); the 1,900-seed subset gained 44.765
(95% CI +34.379 to +55.151). These seeds had been used previously.
See [the evaluation report](../docs/learning_evaluation.md).

The model ships with the repository and uses its MIT license. Experimental
models, training lessons and checkpoints remain ignored in `learning_data/`.
`--model PATH` explicitly selects another model; local training never replaces
the release model automatically.
