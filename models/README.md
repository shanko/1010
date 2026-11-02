# Released learned policy

`learned.json` is the default model, named `learned`. It starts from the
feature-v2 stronger-teacher imitation candidate promoted after #33 (304
lessons, random seed 17, 20 epochs, learning rate 0.1).

Studying the maintainer's 1,184-point game suggested reducing wall preference.
The current release scales wall contact by 0.75 while preserving contact with
occupied cells exactly; all other feature weights remain unchanged. Direct
imitation of the whole demonstration was tested and rejected.

Resolved model SHA-256 (Ruby `JSON.generate(LearnedPlayer.load(path).model)`):
`4a06731303861400f195484161d1d974a077bc75e2f439aed19b23114f371203`.
Parent model SHA-256:
`9347eed45cb853de582b01b0e5a4664a4f387ddd6da4710bb23a71d6fa16e3e4`.

After passing independent tuning confirmation, the frozen candidate gained
43.615 points/game over the parent (95% CI +31.528 to +55.702), and 83.855
points/game over Codex Sam (95% CI +72.745 to +94.965), on 2,000 newly reserved
test seeds. See [the study](../docs/best_score_study.md) for the protocol,
negative experiments, limitations and exact calibration formula.

The model ships with the repository under its MIT license. Experimental
models, training lessons and checkpoints remain ignored in `learning_data/`.
`--model PATH` explicitly selects another model; local training never replaces
the release model automatically. Prior releases remain available in Git.
