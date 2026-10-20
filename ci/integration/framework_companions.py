#!/usr/bin/env python3
"""Resolve declared companions for the existing read-only platform PR entry.

The request validator runs first and still rejects caller-supplied companions
on this entry. This resolver reads only the admitted event and public GitHub
metadata. validate-source-set.sh checks every resolved ref before execution and
again before final acceptance, exactly as for the trusted component entry.
"""
import json
import os
from pathlib import Path
import re
import subprocess

PLATFORM = 'kuasar-sandbox/kuasar-sandbox'
OWNERS = {'accelerator', 'connector', 'guest-runtime', 'sandboxer', 'orchestrator'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def declaration(body):
    body = (body or '').replace('\r', '')
    require('kuasar-bms-companions' not in body, 'obsolete companion declaration')
    active, starts, ends, lines = False, 0, 0, []
    for line in body.splitlines():
        if re.fullmatch(r'<!--[ \t]*kuasar-ci-companions[ \t]*', line):
            require(not active, 'nested companion declaration')
            active = True; starts += 1
        elif active and re.fullmatch(r'[ \t]*-->[ \t]*', line):
            active = False; ends += 1
        elif active and line.strip():
            lines.append(line.strip())
    if not starts:
        require('<!-- kuasar-ci-companions' not in body, 'malformed companion declaration')
        return []
    require(starts == ends == 1 and not active and 1 <= len(lines) <= 5,
            'malformed or empty companion declaration')
    result, seen = [], set()
    for line in lines:
        match = re.fullmatch(r'kuasar-sandbox/([a-z-]+)#([1-9][0-9]*)', line)
        require(match and match[1] in OWNERS and match[1] not in seen, 'invalid or duplicate companion repository')
        seen.add(match[1]); result.append(('kuasar-sandbox/' + match[1], int(match[2])))
    return sorted(result)


def scope(event, env):
    require(env.get('GITHUB_EVENT_NAME') == 'pull_request' and
            env.get('GITHUB_REPOSITORY') == env.get('CANDIDATE_REPOSITORY') == PLATFORM and
            env.get('TRUSTED_WORKFLOW_SHA') == env.get('GITHUB_SHA') == env.get('CANDIDATE_SHA') and
            re.fullmatch('[0-9a-f]{40}', env.get('CANDIDATE_SHA', '')) and
            env.get('COMPANION_CANDIDATES') == '[]' and
            event['repository']['full_name'] == PLATFORM and event['repository'].get('visibility') == 'public' and
            event['pull_request']['head']['repo']['full_name'] == PLATFORM,
            'companion discovery requires the admitted public same-repository framework PR')


def resolve(body, api):
    records = []
    for repository, number in declaration(body):
        pr = api(f'repos/{repository}/pulls/{number}')
        require(pr['number'] == number and pr['state'] == 'open' and pr['draft'] is False and
                pr['base']['repo']['full_name'] == repository and pr['base']['repo']['private'] is False,
                'companion must be an open ready PR in its public owner repository')
        record = {'repository': repository, 'pull_request_number': number,
                  'candidate_sha': pr['merge_commit_sha'], 'base_sha': pr['base']['sha'],
                  'head_sha': pr['head']['sha'], 'base_ref': pr['base']['ref']}
        require(all(isinstance(record[key], str) and re.fullmatch('[0-9a-f]{40}', record[key])
                    for key in ('candidate_sha', 'base_sha', 'head_sha')), 'missing exact companion commit')
        require(re.fullmatch(r'main|release/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.x', record['base_ref']),
                'unsupported companion base branch')
        records.append(record)
    return records


def api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True, timeout=120))


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    scope(event, os.environ)
    value = json.dumps(resolve(event['pull_request'].get('body'), api), separators=(',', ':'))
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write('COMPANION_CANDIDATES=' + value + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('value=' + value + '\n')


if __name__ == '__main__':
    main()
