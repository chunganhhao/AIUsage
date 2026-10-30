"""Offline Hermes integration: real agent/tools, scripted HTTP responses, no provider.

Run with python3 scripts/test_token_saver_hermes.py. Requires an already-working
local Hermes/test profile; no package installers, gateway or real API keys in this test.
Mock usage is deliberately synthetic and is not a token-savings measurement.
"""
import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
HERMES = Path.home() / '.hermes/hermes-agent'
MODEL = 'gemini-3.8-flash-high'
REFERENCE = '''import re
def parse_duration(text):
    match = re.fullmatch(r"([0-9]+)(ms|s|m)", text.strip()) if isinstance(text, str) else None
    if not match: raise ValueError("invalid duration")
    return int(match[1]) * {"ms": 1, "s": 1000, "m": 60000}[match[2]]
'''
TEST = '''import unittest
from app import parse_duration
class DurationTests(unittest.TestCase):
    def test_valid(self):
        for text, result in [("0ms", 0), ("12ms", 12), (" 2s ", 2000), ("3m", 180000)]:
            with self.subTest(text=text): self.assertEqual(parse_duration(text), result)
    def test_invalid(self):
        for text in ["", "-1s", "1.5s", "1 s", "1h", None, 3]:
            with self.subTest(text=text):
                with self.assertRaises(ValueError): parse_duration(text)
'''

def child(home, condition):
    # This subprocess starts with the fixture home, not the user's live Hermes home.
    sys.path[:0] = json.loads(os.environ.pop('AIUSAGE_TEST_PYTHON_PATHS'))
    import socket
    from unittest.mock import patch
    import httpx
    profile = home / '.hermes/profiles/token-saver-test'
    work = profile / 'workspace'
    # Reuse the existing test profile's dependency runtime; fake homes otherwise trigger auto-bootstrap.
    os.environ['HERMES_HOME'] = str(HERMES.parent / 'profiles/token-saver-test')
    os.environ['HERMES_PROFILE'] = 'token-saver-test'
    os.environ['TERMINAL_CWD'] = str(work)
    os.chdir(work)
    requests = []
    blocked_sockets = []
    commands = []
    wrapper = home / 'Library/Application Support/AIUsage/bin/token-saver-rtk'
    import shlex
    import yaml
    fixture_config = yaml.safe_load((profile / 'config.yaml').read_text())
    inspect_command = (shlex.quote(str(wrapper)) + ' git status' if condition == 'on' else 'git status') + ' && cat app.py test_app.py'
    edit_command = "cat > app.py <<'AIUSAGE_FIXTURE'\n" + REFERENCE + "AIUSAGE_FIXTURE\npython3 -m unittest -q"

    def handler(request):
        if request.method != 'POST' or request.url.path != '/v1/chat/completions':
            return httpx.Response(404, json={'error': 'No auxiliary network in fixture'})
        if len(requests) >= 4:
            raise AssertionError('Fixture exceeded four-call budget')
        data = json.loads(request.content)
        assert data['model'] == MODEL
        assert request.url.host == '127.0.0.1' and request.url.port == 14420
        assert request.headers['authorization'] == 'Bearer offline-fixture-only'
        systems = '\n'.join(m.get('content', '') for m in data['messages'] if m['role'] == 'system')
        assert ('<!-- AIUsage Token Saver BEGIN -->' in systems) == (condition == 'on')
        requests.append(data)
        number = len(requests)
        if number < 3:
            cmd = inspect_command if number == 1 else edit_command
            commands.append(cmd)
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': f'fixture-{number}', 'type': 'function', 'function': {'name': 'terminal', 'arguments': json.dumps({'command': cmd})}}]}
            finish = 'tool_calls'
        else:
            assert number == 3
            tools = [m for m in data['messages'] if m['role'] == 'tool']
            assert len(tools) == 2
            assert all(json.loads(m['content'])['exit_code'] == 0 for m in tools), tools
            result = json.loads(tools[-1]['content'])
            assert result['exit_code'] == 0 and 'OK' in result['output'], result
            message = {'role': 'assistant', 'content': 'Đã sửa bộ phân tích thời lượng. python3 -m unittest -q: 2 tests passed.'}
            finish = 'stop'
        usage = {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120}
        common = {'id': f'offline-{number}', 'object': 'chat.completion', 'created': 0, 'model': MODEL}
        if data.get('stream'):
            delta = dict(message); delta['role'] = 'assistant'
            if 'tool_calls' in delta: delta['tool_calls'][0]['index'] = 0
            chunks = [{**common, 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                      {**common, 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}], 'usage': usage}]
            body = ''.join('data: ' + json.dumps(c, ensure_ascii=False) + '\n\n' for c in chunks) + 'data: [DONE]\n\n'
            return httpx.Response(200, headers={'content-type': 'text/event-stream'}, content=body)
        return httpx.Response(200, json={**common, 'choices': [{'index': 0, 'message': message, 'finish_reason': finish}], 'usage': usage})

    real_send = httpx.Client.send
    mock_client = httpx.Client(transport=httpx.MockTransport(handler))
    def mock_send(client, request, *args, **kwargs):
        return real_send(mock_client, request, *args, **kwargs)
    def deny_socket(*args, **kwargs):
        blocked_sockets.append(True)
        raise AssertionError('Real socket connection forbidden in offline test')

    with patch.object(httpx.Client, 'send', mock_send), patch.object(socket.socket, 'connect', deny_socket), patch.object(socket.socket, 'connect_ex', deny_socket), patch('hermes_cli.config.load_config', return_value=fixture_config), patch('hermes_cli.config.load_config_readonly', return_value=fixture_config):
        from run_agent import AIAgent
        from agent.runtime_cwd import set_session_cwd
        from tools.terminal_tool import register_task_env_overrides, terminal_tool
        task_id = 'offline-' + condition
        register_task_env_overrides(task_id, {'cwd': str(work), 'env_type': 'local'})
        set_session_cwd(str(work))
        pwd = json.loads(terminal_tool(command='pwd', task_id=task_id))
        assert pwd['exit_code'] == 0 and Path(pwd['output'].strip()).resolve() == work.resolve()
        before_tests = (work / 'test_app.py').read_bytes()
        before_rules = (work / 'HERMES.md').read_bytes()
        agent = AIAgent(model=MODEL, base_url='http://127.0.0.1:14420/v1', api_key='offline-fixture-only', provider='custom',
                        api_mode='chat_completions', enabled_toolsets=['terminal'], platform='cli', cwd=str(work),
                        max_iterations=4, run_budget_seconds=30, quiet_mode=True, skip_memory=True, skip_background_review=True,
                        save_trajectories=False, session_id='fixture-' + condition)
        try:
            agent._api_max_retries = 1
            outcome = agent.run_conversation('Inspect git status and app.py/test_app.py; implement parse_duration and run the supplied unit tests. Reply in Vietnamese.', task_id=task_id)
            assert outcome['completed'] and not outcome.get('failed'), outcome.get('turn_exit_reason')
            assert len(requests) == 3 and outcome['api_calls'] == 3
            assert 'Đã sửa' in outcome['final_response']
            assert (work / 'test_app.py').read_bytes() == before_tests and (work / 'HERMES.md').read_bytes() == before_rules
            assert (work / 'app.py').read_text() == REFERENCE
            assert not blocked_sockets
            print(json.dumps({'condition': condition, 'completed': True, 'mock_model_calls': 3, 'budget': 4,
                              'real_socket_connections': 0, 'actual_cwd_verified': True,
                              'wrapper_invoked': condition == 'on', 'mock_final_response': outcome['final_response']}, ensure_ascii=False))
        finally:
            agent.close()
            mock_client.close()

class HermesTokenSaverIntegration(unittest.TestCase):
    def test_off_and_on_complete_inside_four_call_budget(self):
        self.assertTrue((HERMES.parent / 'profiles/token-saver-test/config.yaml').is_file(), 'Create the dedicated token-saver-test profile before running this local integration test')
        runtime_env = {k: os.environ[k] for k in ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL'] if k in os.environ}
        runtime_env.update(HERMES_HOME=str(HERMES.parent / 'profiles/token-saver-test'), HERMES_PROFILE='token-saver-test')
        # Query the installed launcher's selected environment, not an arbitrary stale venv.
        listing = subprocess.run(['hermes', '--run-module', 'site'], env=runtime_env, capture_output=True, text=True, check=True).stdout
        paths = ast.literal_eval(listing.split('sys.path = ', 1)[1].split('\nUSER_BASE:', 1)[0].strip())
        packages = [p for p in paths if 'site-packages' in p and Path(p).is_dir()]
        self.assertTrue(packages)
        command = json.loads(subprocess.run(['hermes', '--print-runtime-command', '--', '--version'], env=runtime_env, capture_output=True, text=True, check=True).stdout)
        python = Path(command[0])  # The .venv/bin/python compatibility shim may bootstrap a different home.
        self.assertTrue(python.exists())
        with tempfile.TemporaryDirectory(prefix='token-saver-mock-') as tmp:
            home = Path(tmp)
            profile = home / '.hermes/profiles/token-saver-test'
            work = profile / 'workspace'; work.mkdir(parents=True)
            config = f'''_config_version: 51
model:
  default: {MODEL}
  provider: custom
  base_url: http://127.0.0.1:14420/v1
  api_key: offline-fixture-only
terminal:
  backend: local
  cwd: {work}
tools:
  tool_search:
    enabled: off
memory:
  enabled: false
mcp_servers: {{}}
fallback_providers: []
'''
            (profile / 'config.yaml').write_text(config)
            support = home / 'Library/Application Support/AIUsage'; support.mkdir(parents=True)
            (support / 'token-saver-settings.json').write_text(json.dumps({'rtkEnabled': True, 'cavemanEnabled': True, 'ponytailEnabled': True, 'cavemanMode': 'full'}))
            source = (ROOT / 'QuotaBackend/Sources/QuotaBackend/Utilities/TokenSaverSettings.swift').read_text()
            literal = source.split('public static let rtkWrapper = """\n', 1)[1].split('""" + "\\n"', 1)[0]
            wrapper = support / 'bin/token-saver-rtk'; wrapper.parent.mkdir()
            wrapper.write_text(textwrap.dedent(literal).strip() + '\n'); wrapper.chmod(0o700)
            subprocess.run(['bash', str(ROOT / 'scripts/run_token_saver_hermes_profile.sh'), '--home', str(home)], check=True, capture_output=True, text=True)
            compact = (work / 'HERMES.md').read_text()
            self.assertLess(len(compact.encode()), 2400)
            env = {k: os.environ[k] for k in ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL'] if k in os.environ}
            env.update(HERMES_HOME=str(HERMES.parent / 'profiles/token-saver-test'), HERMES_PROFILE='token-saver-test', AIUSAGE_TEST_PYTHON_PATHS=json.dumps([str(HERMES), *packages]))
            subprocess.run(['git', 'init', '-q', str(work)], check=True)
            for condition in ['off', 'on']:
                (work / 'app.py').write_text('def parse_duration(text):\n    raise NotImplementedError\n')
                (work / 'test_app.py').write_text(TEST)
                (work / 'HERMES.md').write_text(compact if condition == 'on' else '# Offline baseline\n')
                proc = subprocess.run([str(python), '-S', str(Path(__file__).resolve()), '--child', str(home), condition], env=env, cwd=work, capture_output=True, text=True, timeout=60)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                receipt = json.loads(proc.stdout.strip().splitlines()[-1])
                self.assertTrue(receipt['completed'])
                self.assertEqual(receipt['mock_model_calls'], 3)
                print(json.dumps(receipt, ensure_ascii=False))

if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--child': child(Path(sys.argv[2]), sys.argv[3])
    else: unittest.main()
