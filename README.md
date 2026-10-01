# Flappy Bird (Godot 4) + RL bridge

A Flappy Bird clone for Godot 4.7 with no asset files: graphics are drawn and
sounds synthesized in code. It also exposes a TCP bridge so an external
program, such as a Python reinforcement-learning trainer, can play it. A PPO
agent trained through that bridge is included.

## Play

```sh
godot --path .            # or open project.godot in the editor and press F5
```

| Input | Action |
|---|---|
| Space / Up / W / Enter / left-click / tap | Flap (also starts and restarts) |
| M | Mute or unmute |
| Esc | Quit |

Your best score is saved to `user://highscore.save`.

## Project layout

```
project.godot      432x768 portrait window, GL Compatibility renderer
main.tscn          single scene; the root node runs main.gd
main.gd            the whole game: physics, pipes, drawing, UI, sound, agent API
rl_bridge.gd       TCP server added only when the game is started with --rl
python/            Gymnasium env, training and playback scripts (uv project)
  flappy_env.py    FlappyBirdEnv: launches Godot and speaks the bridge protocol
  check_env.py     API check, scripted-policy smoke test, throughput, determinism
  train.py         PPO training (Stable-Baselines3), parallel headless Godot processes
  play.py          watch or benchmark a trained model
  models/best_model.zip   trained agent
```

`python/.gdignore` stops Godot from scanning the Python folder and its `.venv`.

## Tuning the game

The constants at the top of `main.gd` control how the game feels: `GRAVITY`,
`FLAP_VELOCITY`, `PIPE_GAP`, `PIPE_SPEED`, `PIPE_SPACING`. Sounds are defined
in `_setup_sounds()`. Changing the physics or pipe constants changes what the
agent sees, so retrain afterwards.

## Controlling the game from another program

Start Godot with user arguments after `--`:

```sh
godot --headless --path . -- --rl --port=11008          # fast, no window (training)
godot --path . -- --rl --port=11008 --watch             # windowed, real-time pacing
```

In `--rl` mode, keyboard and mouse input is ignored, the game advances only
when told to, and the best score is not saved. The bridge listens on
`127.0.0.1` and speaks newline-delimited JSON, with one response per request:

| Request | Response |
|---|---|
| `{"cmd": "reset", "seed": 123}` | `{"obs": [...], "score": 0}` |
| `{"cmd": "step", "action": 0\|1, "repeat": 2}` | `{"obs": [...], "reward": 0.1, "terminated": false, "score": 3}` |
| `{"cmd": "close"}` | *(Godot quits)* |

- **Timing:** the game runs at a fixed 60 ticks per second. `repeat` is how
  many ticks one step advances, and action `1` flaps on the first of them.
- **Seeds:** pipe heights come from a seeded RNG, so the same seed and the
  same actions replay the same game.
- **Observation** (6 floats, roughly within [-1, 1]):
  1. bird height ÷ play-area height
  2. bird vertical velocity ÷ max fall speed
  3. next pipe: distance to its far edge ÷ screen width
  4. next pipe: gap center minus bird height, ÷ play-area height
  5. and 6. the same two values for the pipe after that

  If a pipe hasn't spawned yet, it reads as `1.0, 0.0` (far away, level with
  the bird).
- **Reward per step:** +0.1 for surviving, +1 per pipe passed, −1 on crashing.

## Python: training and watching the agent

Requires [uv](https://docs.astral.sh/uv/) and Godot. The environment finds
Godot through `$GODOT_BIN`, then `godot` on `PATH`, then
`/Applications/Godot.app`.

```sh
cd python
uv sync --locked --extra train                                 # install exactly what uv.lock pins
uv run --locked check_env.py                                   # check the environment works
uv run --locked --extra train play.py                          # watch the included agent play
uv run --locked --extra train play.py --headless -n 20         # score it on 20 games
uv run --locked --extra train train.py --timesteps 1000000     # retrain from scratch
```

### Reproducibility

The results below were produced with these versions:

| Component | Version | Pinned by |
|---|---|---|
| Godot | 4.7.2 | not pinned; install this version yourself |
| Python | 3.14.7 | `python/.python-version` (`3.14`; uv downloads it if missing) |
| torch, stable-baselines3, gymnasium, numpy, … | 2.14.0, 2.9.0, 1.3.0, 2.5.3, … | `python/uv.lock` (exact versions and sha256 hashes for macOS arm64, Linux and Windows) |

- **Always pass `--locked`.** It makes uv fail if `pyproject.toml` and
  `uv.lock` disagree, instead of silently re-resolving and updating the lock.
- **Other Python versions:** `requires-python` allows 3.10+, but on 3.10 or
  3.11 the lock selects a different numpy. Use 3.14 to match the results
  exactly.
- **Retraining:** training is seeded (`--seed`, default 0). On the same
  machine and versions, two runs with the same seed produce bit-identical
  weights. Other CPUs or operating systems may give slightly different
  numbers, but training should reach similar scores.
- **Adding or upgrading packages:** use `uv add <pkg>` or
  `uv lock --upgrade-package <pkg>`, then commit `pyproject.toml` and
  `uv.lock` together.

`train.py` runs 8 headless Godot processes in parallel. It writes
`models/best_model.zip` (best evaluation) and `models/ppo_flappy.zip` (final
weights). `play.py` and training must use the same `--frame-skip` (default 2).

### Results for the included model

- **Training:** PPO with a 64×64 MLP, 8 parallel environments, 1M steps. It
  took about 2 minutes on an Apple Silicon Mac.
- **Learning curve:** by about 200k steps, the agent reached the 5,000-step
  cap in every evaluation game.
- **Test:** 20 new seeds with a 20,000-step cap. It hit the cap (424 pipes) in
  18 games; the other two ended at 40 and 197 pipes.
- **Speed:** one headless environment runs about 12,500 steps per second.
