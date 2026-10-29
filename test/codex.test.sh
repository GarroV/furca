#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
root = pathlib.Path.cwd()
with tempfile.TemporaryDirectory() as tmp:
    home = pathlib.Path(tmp)
    codex = home/'codex with spaces'
    env = dict(os.environ, HOME=str(home), CODEX_HOME=str(codex))
    env.pop('CODEX_THREAD_ID', None)
    (home/'.claude').mkdir()
    original = '{"owner": "do not touch"}'
    (home/'.claude/settings.json').write_text(original)
    codex.mkdir()
    (codex/'hooks.json').write_text(json.dumps({'owner':True, 'hooks':{'Stop':[{
        'hooks':[{'type':'command','command':'echo orca-owned'}]}]}}))
    def run(args, ok=0, payload=None, cwd=None):
        p = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                           env=env, cwd=cwd, text=True, capture_output=True)
        assert p.returncode == ok, (args, p.returncode, p.stdout, p.stderr)
        return p.stdout
    install = ['bash',str(root/'install.sh'),'--runtime','codex']
    run(install); run(install)
    assert (home/'.claude/settings.json').read_text() == original
    settings = json.loads((codex/'hooks.json').read_text())
    assert settings['owner'] and settings['hooks']['Stop'][0]['hooks'][0]['command'] == 'echo orca-owned'
    assert len(settings['hooks']['Stop']) == 2
    assert len(list((codex/'agents').glob('*.toml'))) == 6
    for name in ['artifex','artifex-hard','lector','norma','optio','exploratio']:
        d = {k.strip():json.loads(v) for k,v in (line.split(' = ',1) for line in
             (codex/'agents'/(name+'.toml')).read_text().splitlines() if ' = ' in line)}
        assert d['name'] == name and d['model'].startswith('gpt-')
        assert d['developer_instructions'] and d['model_reasoning_effort']
        if name == 'artifex-hard': assert d['model'] == 'gpt-6-astra'
    fabrica = (codex/'skills/fabrica/SKILL.md').read_text()
    assert '5а. **Контекст Codex.**' in fabrica
    assert "'.claude'/'settings.json'" not in fabrica and '~/.claude' not in fabrica
    assert 'нативная роль `artifex-hard`' in fabrica
    assert '\nmodel: gpt-6.1-sol\n' in (codex/'furca/runtime/agents/artifex.md').read_text()
    config=(codex/'furca/runtime/config.defaults.md').read_text()
    assert '## Codex models' in config and 'Opus 5.5' not in config
    checker = ['python3',str(root/'adapters/codex/install.py'),'--check']
    run(checker)
    hook_config = codex/'hooks.json'
    saved_hooks = hook_config.read_text()
    for mutation in ('matcher','async'):
        altered = json.loads(saved_hooks)
        group = altered['hooks']['PreToolUse'][0]
        if mutation == 'matcher': group['matcher'] = '^NEVER_MATCH$'
        else: group['hooks'][0]['async'] = True
        hook_config.write_text(json.dumps(altered))
        run(checker, ok=1)
    hook_config.write_text(saved_hooks)
    run(checker)
    role = codex/'agents/lector.toml'
    original_role = role.read_text()
    role.write_text(original_role.replace('model =', 'wrong_model =', 1))
    run(checker, ok=1)
    role.write_text(original_role); run(checker)
    project = home/'project'; project.mkdir()
    run(['git','init','-q',str(project)])
    tasks = '| T001 | api | todo | feature |\n'
    (project/'tasks.md').write_text(tasks)
    continuity = ['python3',str(root/'adapters/codex/continuity.py')]
    run(continuity+['--start',str(project)], ok=2)
    run(continuity+['--start',str(project),'test-codex-session'])
    hook = ['python3',str(root/'adapters/codex/hook.py')]
    base = {'hook_event_name':'PreToolUse','cwd':str(project),'session_id':'test-codex-session'}
    def denied(payload):
        result = json.loads(run(hook, payload=base|payload))
        assert result['hookSpecificOutput']['permissionDecision'] == 'deny', result
    denied({'tool_name':'Bash','tool_input':{'command':'git add .'}})
    assert not run(hook, payload=base|{'tool_name':'Bash','tool_input':{'command':'git add tasks.md'}})
    patch = '*** Begin Patch\n*** Update File: tasks.md\n@@\n+| T001 | another | todo | feature |\n*** End Patch'
    denied({'tool_name':'apply_patch','tool_input':{'command':patch}})
    patch = patch.replace('T001','T002')
    assert not run(hook, payload=base|{'tool_name':'apply_patch','tool_input':{'command':patch}})
    assert (project/'tasks.md').read_text() == tasks, 'inspection executed the patch'
    repeated = patch.replace('*** End Patch','*** Update File: ./tasks.md\n@@\n+| T002 | duplicate | todo | feature |\n*** End Patch')
    run(hook, ok=2, payload=base|{'tool_name':'apply_patch','tool_input':{'command':repeated}})
    moved = '*** Begin Patch\n*** Update File: draft.md\n*** Move to: tasks.md\n@@\n+| T001 | duplicate | todo | feature |\n*** End Patch'
    run(hook, ok=2, payload=base|{'tool_name':'apply_patch','tool_input':{'command':moved}})
    denied({'tool_name':'spawn_agent','tool_input':{'agent_type':'artifex-hard','message':'work on {{port range}}'}})
    image = project/'large.png'; image.write_bytes(b'x'*100000)
    denied({'tool_name':'view_image','tool_input':{'path':str(image)}})
    assert not run(hook, payload=base|{'agent_type':'norma','tool_name':'view_image','tool_input':{'path':str(image)}})
    run(hook, payload={'hook_event_name':'SubagentStart','session_id':'parent',
                      'agent_id':'native-norma-id','agent_type':'norma','model':'gpt-6.1-sol'})
    assert not run(hook, payload=base|{'agent_id':'native-norma-id','tool_name':'view_image','tool_input':{'path':str(image)}})
    denied({'session_id':'parent','tool_name':'view_image','tool_input':{'path':str(image)}})
    # A live worker releases the parent; a terminal event restores continuation.
    run(hook, payload={'hook_event_name':'SubagentStart','session_id':'test-codex-session',
                      'agent_id':'block-id','agent_type':'artifex','model':'gpt-6.1-sol'})
    run(hook, payload={'hook_event_name':'Stop','session_id':'test-codex-session','cwd':str(project)})
    run(hook, payload={'hook_event_name':'SubagentStop','session_id':'test-codex-session',
                      'agent_id':'block-id','agent_type':'artifex','model':'gpt-6.1-sol'})
    stopped = subprocess.run(hook,env=env,text=True,capture_output=True,input=json.dumps(
        {'hook_event_name':'Stop','session_id':'test-codex-session','cwd':str(project)}))
    assert stopped.returncode==2
    assert '/hooks/keep-building.py --stop' not in stopped.stderr
    # Unknown tool payloads fail visibly, not a fake positive check.
    run(hook, ok=2, payload=base|{'tool_name':'apply_patch','tool_input':{}})
    run(continuity+['--stop',str(project)])
    assert not run(hook, payload=base|{'tool_name':'Bash','tool_input':{'command':'git add .'}})
    run(continuity+['--off'])
    settings = json.loads((codex/'hooks.json').read_text())
    assert settings['hooks']['Stop'][0]['hooks'][0]['command'] == 'echo orca-owned'
    assert (home/'.claude/settings.json').read_text() == original
    run(checker, ok=1)
    # A directory link must not make a Codex installation write under Claude.
    import shutil
    shutil.rmtree(codex/'agents')
    legacy_agents=home/'.claude/agents';legacy_agents.mkdir()
    (codex/'agents').symlink_to(legacy_agents)
    run(install, ok=1)
    assert list(legacy_agents.iterdir())==[]
print('PASS: Codex install isolation, stale checks, hard role, normalized tool guards and negative cases')
PY
