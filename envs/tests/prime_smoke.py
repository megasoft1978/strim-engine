"""Run under the Prime-only interpreter, launched by the main pytest suite."""
import asyncio
import json

import verifiers.v1 as vf

from strim_envs.core import CORPUS, TASK_IDS, task


async def main():
    config = vf.SingleAgentEnvConfig(taskset={'id': 'strim-envs'},
                                     agent={'harness': {'id': 'null'}})
    environment = vf.load_environment(config)
    tasks = list(environment.taskset)
    assert len(tasks) == 16
    assert tuple(t.data.task_id for t in tasks) == TASK_IDS
    for t in tasks:
        assert t.data.network_allow == []
        # The JSON context starts after the final double newline.
        source = json.loads(t.data.prompt_text.rsplit('\n\n', 1)[1])
        for name in source:
            assert name not in ('solution.patch', 'task.json', 'snapshot.tar.gz')
            assert not any(name == p or name.startswith(p + '/')
                           for p in task(t.data.task_id)['test_paths'])
    selected = tasks[0]
    patch = (CORPUS / 'tasks/js-01/solution.patch').read_text()
    results = {}
    for name, answer in [('reference', patch), ('broken', ''), ('invalid', 'not a patch'),
                         ('tampered', patch + '\ndiff --git a/test/extra.js b/test/extra.js\n'
                          'new file mode 100644\n--- /dev/null\n+++ b/test/extra.js\n@@ -0,0 +1 @@\n+bad\n')]:
        trace = vf.Trace(task=vf.TraceTask(type=type(selected).__name__, data=selected.data),
                         agent=vf.AgentInfo(config=config.agent), root_reply=answer)
        await selected.score(trace)
        results[name] = trace.reward
        assert trace.rewards['correctness'] is not None
    assert results == {'reference': 1.0, 'broken': 0.0, 'invalid': 0.0, 'tampered': 0.0}, results
    print(json.dumps({'tasks': len(tasks), **results}))


if __name__ == '__main__':
    asyncio.run(main())
