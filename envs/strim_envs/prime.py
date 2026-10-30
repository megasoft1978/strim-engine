"""Prime verifiers 0.4 taskset: source context in, unified source patch out.

No shell harness is required: only the final patch is sent to the trusted local
verifier, after the model's turn. This keeps private assets out of the rollout.
"""
from __future__ import annotations

import asyncio
import json
import re
import shlex

import verifiers.v1 as vf

from .core import TASK_IDS
from .episode import Episode, MAX_TEXT, task_prompt


def score_patch(task_id: str, answer: str) -> float:
    patch = answer.strip()
    fenced = re.fullmatch(r'```(?:diff|patch)?\s*\n(.*?)\n```', patch, re.DOTALL)
    if fenced:
        patch = fenced.group(1)
    if len(patch.encode()) > MAX_TEXT:
        return 0.0
    episode = Episode(task_id)
    try:
        if patch:
            # Quote the entire patch as data. git apply never executes its contents.
            command = 'printf %s ' + shlex.quote(patch + '\n') + ' | git apply --no-index -'
            if episode.act('bash', command=command)['exit_code'] != 0:
                return 0.0
        return episode.act('finish')['reward']
    finally:
        episode.close()


class StrimTaskData(vf.TaskData):
    task_id: str


class StrimTask(vf.Task[StrimTaskData]):
    @vf.stop
    async def single_turn(self, trace: vf.Trace) -> bool:
        return trace.num_turns >= 1

    @vf.reward(weight=1.0)
    async def correctness(self, trace: vf.Trace) -> float:
        return await asyncio.to_thread(score_patch, self.data.task_id, trace.last_reply)


class StrimTasksetConfig(vf.TasksetConfig):
    task_ids: tuple[str, ...] = TASK_IDS


class StrimTaskset(vf.Taskset[StrimTask, StrimTasksetConfig]):
    def load(self):
        for task_id in self.config.task_ids:
            episode = Episode(task_id)
            try:
                source = {name: episode.read(name).decode('utf-8', errors='replace')
                          for name in episode.files()}
                prompt = (task_prompt(task_id) + '\n\nPrime patch mode: the public workspace '
                          'is supplied as a JSON mapping of paths to file contents below. '
                          'Reply with a unified git diff that fixes the source. Do not include '
                          'prose. The patch is applied to a fresh public workspace and graded '
                          'offline after your final reply.\n\n' + json.dumps(source))
                yield StrimTask(StrimTaskData(id=task_id, task_id=task_id, prompt=prompt,
                                             network_allow=[]), self.config.task)
            finally:
                episode.close()
