"""Watch a trained agent play in the Godot window (or benchmark it headless).

    uv run --extra train play.py                     # models/best_model.zip, windowed
    uv run --extra train play.py --headless -n 20    # score 20 episodes quickly
"""

import argparse
from pathlib import Path

from stable_baselines3 import PPO

from flappy_env import FlappyBirdEnv

HERE = Path(__file__).resolve().parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", nargs="?", type=Path, default=HERE / "models" / "best_model.zip")
    parser.add_argument("-n", "--episodes", type=int, default=5)
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--frame-skip", type=int, default=2, help="must match training")
    parser.add_argument("--max-steps", type=int, default=20_000)
    args = parser.parse_args()

    model = PPO.load(args.model, device="cpu")
    env = FlappyBirdEnv(
        render_mode=None if args.headless else "human",
        frame_skip=args.frame_skip,
        max_steps=args.max_steps,
    )
    scores = []
    try:
        for episode in range(args.episodes):
            obs, _ = env.reset(seed=1_000_000 + episode)
            done = False
            while not done:
                action, _ = model.predict(obs, deterministic=True)
                obs, _, terminated, truncated, info = env.step(action)
                done = terminated or truncated
            scores.append(info["score"])
            print(f"episode {episode}: score {info['score']}{' (hit step cap)' if truncated else ''}")
    finally:
        env.close()
    print(f"mean score {sum(scores) / len(scores):.1f}, best {max(scores)}")


if __name__ == "__main__":
    main()
