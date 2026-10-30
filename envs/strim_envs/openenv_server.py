"""OpenEnv 0.11 server and typed client (official Gym-style protocol)."""
from __future__ import annotations

import random
from typing import Literal
from uuid import uuid4

from openenv.core import EnvClient
from openenv.core.client_types import StepResult
from openenv.core.env_server.http_server import create_app
from openenv.core.env_server.interfaces import Environment
from openenv.core.env_server.types import Action, Observation, State
from pydantic import Field

from .core import TASK_IDS, task
from .episode import Episode, MAX_OBS_FILES, MAX_TEXT, clip, task_prompt


class StrimAction(Action):
    operation: Literal['read', 'list', 'grep', 'edit', 'write', 'bash', 'finish']
    path: str = Field(default='.', max_length=4096)
    content: str = Field(default='', max_length=MAX_TEXT)
    old_text: str = Field(default='', max_length=MAX_TEXT)
    new_text: str = Field(default='', max_length=MAX_TEXT)
    pattern: str = Field(default='', max_length=4096)
    command: str = Field(default='', max_length=MAX_TEXT)
    timeout: float = Field(default=10, gt=0, le=10)


class StrimObservation(Observation):
    task_id: str
    prompt: str = ''
    files: list[str] = Field(default_factory=list)
    output: str = ''
    exit_code: int = 0


class StrimEnvironment(Environment[StrimAction, StrimObservation, State]):
    SUPPORTS_CONCURRENT_SESSIONS = True

    def __init__(self):
        super().__init__()
        self.episode: Episode | None = None
        self._state = State(episode_id=str(uuid4()), step_count=0)

    def reset(self, seed=None, episode_id=None, task_id=None, **kwargs):
        task_id = task_id or random.Random(seed).choice(TASK_IDS)
        task(task_id)  # Validate before discarding an existing episode.
        self.close()
        self.episode = Episode(task_id)
        self._state = State(episode_id=episode_id or str(uuid4()), step_count=0)
        files = self.episode.files()
        if len(files) > MAX_OBS_FILES:
            files = files[:MAX_OBS_FILES] + [f'... {len(files) - MAX_OBS_FILES} more; use the list operation']
        return StrimObservation(task_id=task_id, prompt=clip(task_prompt(task_id), 6000),
                                files=files, done=False, reward=0.0)

    def step(self, action: StrimAction, timeout_s=None, **kwargs):
        # Never raise: an error in an action is an observation, not an HTTP 500.
        if self.episode is None:
            return StrimObservation(task_id='', output='no episode; reset first', exit_code=1,
                                    done=True, reward=0.0)
        episode = self.episode
        try:
            values = action.model_dump(exclude={'metadata'})
            if timeout_s is not None:
                values['timeout'] = max(0.01, min(values['timeout'], timeout_s))
            if episode.done:
                result = dict(output='episode is finished; reset first', exit_code=1,
                              done=True, reward=episode.reward)
            else:
                result = episode.act(**values)
        except Exception as exc:
            result = dict(output=clip(f'{type(exc).__name__}: {exc}'), exit_code=1,
                          done=episode.done, reward=episode.reward if episode.done else 0.0)
        self._state.step_count = episode.steps
        return StrimObservation(task_id=episode.task_id, **result)

    @property
    def state(self):
        return self._state

    def close(self):
        if self.episode is not None:
            self.episode.close()
            self.episode = None


class StrimClient(EnvClient[StrimAction, StrimObservation, State]):
    def _step_payload(self, action):
        return action.model_dump()

    def _parse_result(self, payload):
        obs = StrimObservation(**payload['observation'],
                               done=payload['done'], reward=payload.get('reward'))
        return StepResult(observation=obs, done=obs.done, reward=obs.reward)

    def _parse_state(self, payload):
        return State(**payload)


app = create_app(StrimEnvironment, StrimAction, StrimObservation,
                 env_name='strim_envs', max_concurrent_envs=4)
