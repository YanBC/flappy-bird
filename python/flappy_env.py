"""Gymnasium environment that plays the Godot Flappy Bird game over a local socket.

Each environment instance launches its own Godot process (headless by default)
running the game with ``-- --rl --port=N`` and talks to rl_bridge.gd using
newline-delimited JSON.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import gymnasium as gym
import numpy as np
from gymnasium import spaces

PROJECT_DIR = Path(__file__).resolve().parent.parent
MACOS_APP_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"


def find_godot() -> str:
    for candidate in (os.environ.get("GODOT_BIN"), shutil.which("godot"), MACOS_APP_BIN):
        if candidate and Path(candidate).exists():
            return candidate
    raise FileNotFoundError("Godot not found; set GODOT_BIN to the Godot executable")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FlappyBirdEnv(gym.Env):
    """Actions: 0 = do nothing, 1 = flap.

    Observation (6 floats): bird height, bird vertical velocity, then for the
    next two pipes the distance to the pipe's far edge and the gap center's
    offset from the bird, all normalized to roughly [-1, 1].

    Reward per step: +0.1 alive, +1 per pipe passed, -1 on crash.
    """

    metadata = {"render_modes": ["human"], "render_fps": 30}

    def __init__(
        self,
        render_mode: str | None = None,
        frame_skip: int = 2,
        max_steps: int = 5000,
        godot_bin: str | None = None,
        project_dir: str | Path = PROJECT_DIR,
        port: int | None = None,
        verbose: bool = False,
        connect_timeout: float = 30.0,
    ):
        assert render_mode is None or render_mode in self.metadata["render_modes"]
        self.render_mode = render_mode
        self.frame_skip = frame_skip
        self.max_steps = max_steps
        self.action_space = spaces.Discrete(2)
        self.observation_space = spaces.Box(-2.0, 2.0, shape=(6,), dtype=np.float32)
        self._steps = 0

        port = port or _free_port()
        args = [godot_bin or find_godot(), "--path", str(project_dir)]
        if render_mode != "human":
            args.append("--headless")
        args += ["--", "--rl", f"--port={port}"]
        if render_mode == "human":
            args.append("--watch")
        output = None if verbose else subprocess.DEVNULL
        self._proc = subprocess.Popen(args, stdout=output, stderr=output)
        self._sock = self._connect(port, connect_timeout)
        self._reader = self._sock.makefile("rb")

    def _connect(self, port: int, timeout: float) -> socket.socket:
        deadline = time.monotonic() + timeout
        while True:
            if self._proc.poll() is not None:
                raise RuntimeError(
                    f"Godot exited with code {self._proc.returncode} before the bridge "
                    "came up; run with verbose=True to see its output"
                )
            try:
                sock = socket.create_connection(("127.0.0.1", port), timeout=1.0)
            except OSError:
                if time.monotonic() > deadline:
                    self._proc.kill()
                    raise TimeoutError(f"could not connect to Godot on port {port}")
                time.sleep(0.1)
                continue
            sock.settimeout(None)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return sock

    def _request(self, msg: dict) -> dict:
        self._sock.sendall(json.dumps(msg).encode() + b"\n")
        line = self._reader.readline()
        if not line:
            raise ConnectionError("Godot closed the connection")
        resp = json.loads(line)
        if "error" in resp:
            raise RuntimeError(f"bridge error: {resp['error']}")
        return resp

    def reset(self, *, seed: int | None = None, options: dict | None = None):
        super().reset(seed=seed)
        game_seed = int(self.np_random.integers(0, 2**31 - 1))
        resp = self._request({"cmd": "reset", "seed": game_seed})
        self._steps = 0
        return np.asarray(resp["obs"], dtype=np.float32), {"score": 0}

    def step(self, action):
        resp = self._request({"cmd": "step", "action": int(action), "repeat": self.frame_skip})
        self._steps += 1
        terminated = bool(resp["terminated"])
        truncated = not terminated and self._steps >= self.max_steps
        obs = np.asarray(resp["obs"], dtype=np.float32)
        return obs, float(resp["reward"]), terminated, truncated, {"score": resp["score"]}

    def render(self):
        # In "human" mode the Godot window renders itself.
        return None

    def close(self):
        if getattr(self, "_sock", None) is not None:
            try:
                self._sock.sendall(b'{"cmd": "close"}\n')
            except OSError:
                pass
            self._reader.close()
            self._sock.close()
            self._sock = None
        if getattr(self, "_proc", None) is not None:
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
            self._proc = None
