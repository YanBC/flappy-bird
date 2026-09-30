"""Train a PPO agent to play Flappy Bird, one headless Godot process per parallel env.

    uv run --extra train train.py --timesteps 1000000

Writes models/ppo_flappy.zip (final) and models/best_model.zip (best evaluation).
"""

import argparse
from collections import deque
from pathlib import Path

import numpy as np
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback, EvalCallback
from stable_baselines3.common.env_util import make_vec_env
from stable_baselines3.common.vec_env import SubprocVecEnv

from flappy_env import FlappyBirdEnv

HERE = Path(__file__).resolve().parent


class ScoreLogger(BaseCallback):
    """Adds the mean pipes-passed score of recent episodes to SB3's progress table."""

    def __init__(self):
        super().__init__()
        self.scores = deque(maxlen=100)

    def _on_step(self) -> bool:
        for info in self.locals["infos"]:
            if "episode" in info:
                self.scores.append(info["episode"]["score"])
        if self.scores:
            self.logger.record("rollout/ep_score_mean", float(np.mean(self.scores)))
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--timesteps", type=int, default=1_000_000)
    parser.add_argument("--n-envs", type=int, default=8)
    parser.add_argument("--frame-skip", type=int, default=2)
    parser.add_argument("--max-steps", type=int, default=5000, help="episode cap (5000 steps ~ 115 pipes)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", type=Path, default=HERE / "models")
    args = parser.parse_args()

    env_kwargs = dict(frame_skip=args.frame_skip, max_steps=args.max_steps)
    env = make_vec_env(
        FlappyBirdEnv,
        n_envs=args.n_envs,
        seed=args.seed,
        env_kwargs=env_kwargs,
        vec_env_cls=SubprocVecEnv,
        monitor_kwargs=dict(info_keywords=("score",)),
    )
    eval_env = make_vec_env(FlappyBirdEnv, n_envs=1, seed=args.seed + 10_000, env_kwargs=env_kwargs)

    model = PPO(
        "MlpPolicy",
        env,
        n_steps=512,
        batch_size=1024,
        n_epochs=10,
        learning_rate=3e-4,
        gamma=0.99,
        gae_lambda=0.95,
        ent_coef=0.01,
        policy_kwargs=dict(net_arch=[64, 64]),
        seed=args.seed,
        device="cpu",
        verbose=1,
    )
    callbacks = [
        ScoreLogger(),
        EvalCallback(
            eval_env,
            n_eval_episodes=5,
            eval_freq=max(50_000 // args.n_envs, 1),
            best_model_save_path=str(args.out),
            deterministic=True,
            verbose=1,
        ),
    ]
    try:
        model.learn(total_timesteps=args.timesteps, callback=callbacks)
    finally:
        args.out.mkdir(parents=True, exist_ok=True)
        model.save(args.out / "ppo_flappy")
        print(f"saved {args.out / 'ppo_flappy.zip'}")
        env.close()
        eval_env.close()


if __name__ == "__main__":
    main()
