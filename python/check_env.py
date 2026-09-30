"""Sanity-check the environment: Gymnasium API conformance, a scripted policy, and throughput.

    uv run check_env.py
"""

import time

from gymnasium.utils.env_checker import check_env

from flappy_env import FlappyBirdEnv


def scripted_policy(obs) -> int:
    # Flap when falling and the bird is below the next gap's center.
    bird_vy, gap_offset = obs[1], obs[3]
    return int(bird_vy > 0 and gap_offset < -0.035)


def main() -> None:
    env = FlappyBirdEnv()
    try:
        check_env(env, skip_render_check=True)
        print("gymnasium check_env: OK")

        total_steps, start = 0, time.perf_counter()
        for episode in range(5):
            obs, _ = env.reset(seed=episode)
            done, info, ret = False, {}, 0.0
            while not done:
                obs, reward, terminated, truncated, info = env.step(scripted_policy(obs))
                ret += reward
                total_steps += 1
                done = terminated or truncated
            print(f"episode {episode}: score={info['score']} return={ret:.1f} "
                  f"{'truncated' if truncated else 'crashed'}")
        elapsed = time.perf_counter() - start
        print(f"{total_steps} steps in {elapsed:.1f}s -> {total_steps / elapsed:.0f} steps/s")

        # Same seed must reproduce the same pipe layout.
        a, _ = env.reset(seed=42)
        for _ in range(60):
            a, *_ = env.step(0)
        b, _ = env.reset(seed=42)
        for _ in range(60):
            b, *_ = env.step(0)
        assert (a == b).all(), "seeded resets are not deterministic"
        print("determinism: OK")
    finally:
        env.close()


if __name__ == "__main__":
    main()
