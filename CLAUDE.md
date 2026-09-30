# CLAUDE.md

Flappy Bird in Godot 4.7 (GDScript) plus a Python RL stack that drives it over TCP.
See README.md for the user-facing overview and the bridge protocol.

## Architecture

- `main.gd` holds the entire game. There are no child scenes and no asset files:
  visuals are drawn in `_draw()` and sounds are synthesized in
  `_setup_sounds()`. Keep it that way; don't add image or audio files.
- The simulation advances only through `_tick(delta)`. In human mode,
  `_physics_process` calls it (60 Hz). In agent mode, `agent_step()` calls it
  with the constant `TICK`. `_process` only requests redraws, and skips even
  that when headless. Don't put game logic in `_process`.
- Pipe gaps use `rng` (seedable). Anything that should be reproducible for
  agents must use `rng`, not the global `randf`. Cosmetic randomness (clouds,
  flap pitch) may use the globals.
- Agent API in `main.gd`: `agent_reset(seed)`, `agent_step(flap) -> crashed`,
  `agent_observation()`. `rl_bridge.gd` owns the socket, JSON protocol,
  frame repeat and rewards.
- `python/flappy_env.py` is the only Python code that speaks the protocol.
  Each env instance spawns its own Godot process on a free port.

## Coupled changes

- **Protocol:** the JSON messages, observation length and reward constants are
  defined in both `rl_bridge.gd`/`main.gd` and `flappy_env.py`
  (`observation_space`, docstrings). Change them together and update the table
  in README.md.
- **Retraining:** changing the observation, rewards, physics constants or pipe
  constants makes `python/models/best_model.zip` stale. Retrain and update the
  README results, or say explicitly that you didn't.
- **Frame skip:** `play.py` must use the same `--frame-skip` as training
  (default 2).

## Commands

```sh
# Game (from repo root)
godot --path .                                        # play
godot --headless --path . --quit-after 120            # smoke test: look for SCRIPT ERROR lines

# Python (from python/)
uv run check_env.py                                   # gymnasium check_env, scripted policy, steps/s, determinism
uv run --extra train train.py --timesteps 1000000     # ~2 min
uv run --extra train play.py --headless -n 20         # evaluate
uv run --extra train play.py                          # windowed watch mode
```

To test the game without the Python stack, write a throwaway `extends SceneTree`
script in the project root. It should instantiate `res://main.tscn`, call
`agent_reset`/`agent_step` or read `state`, `bird_y` and `pipes`. Run it with
`godot --headless --path . -s res://<script>.gd`, then delete it.

## Conventions

- **Style:** tabs, static typing (`:=`, typed arrays, return types), constants
  in UPPER_SNAKE at the top of `main.gd`, and `# --- Section ---` dividers.
  Prefixing private helpers with `_` is fine; the bridge calls only the
  `agent_*` functions and reads `score`.
- **Python:** type hints, Python >=3.10, Gymnasium API (5-tuple `step`).
  Keep runtime deps to `gymnasium` and `numpy`; training-only deps go in the
  `train` extra.
- `python/.gdignore` must stay, so Godot doesn't scan `.venv`.
- Commit `*.gd.uid` files. Don't commit `.godot/`.

## Sandbox gotchas (Claude Code)

- The bridge binds a localhost port, and Python's `_free_port()` binds one too.
  Both fail with EPERM in the sandbox unless
  `sandbox.network.allowLocalBinding` is enabled.
- Windowed Godot (non-`--headless`, including `--watch`) hangs inside the
  sandbox. Use headless runs for verification.
- `~/.cache/uv` isn't writable in the sandbox. Set
  `UV_CACHE_DIR=$TMPDIR/uv-cache`, and unset any inherited `VIRTUAL_ENV`.
- Godot logs errors about `user://` and editor settings when it can't write
  to `~/Library/Application Support/Godot`. That's harmless for tests.
