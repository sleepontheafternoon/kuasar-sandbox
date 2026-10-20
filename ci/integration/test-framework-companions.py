#!/usr/bin/env python3
import copy
import unittest
import framework_companions as subject


class Companions(unittest.TestCase):
    def test_strict_declaration(self):
        block = '<!-- kuasar-ci-companions\nkuasar-sandbox/connector#95\n-->\n'
        self.assertEqual(subject.declaration(block), [('kuasar-sandbox/connector', 95)])
        self.assertEqual(subject.declaration('ordinary prose'), [])
        for body in (block + block, block.replace('-->', ''), '<!-- kuasar-ci-companions -->',
                     block.replace('connector', 'kuasar-sandbox'), block.replace('#95', '#0'),
                     block.replace('kuasar-sandbox/', 'outside/'), block.replace('connector#95', 'connector#95\nkuasar-sandbox/connector#96'),
                     '<!-- kuasar-ci-companions\n-->\n', 'kuasar-bms-companions'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                subject.declaration(body)

    def test_only_public_same_repository_exact_framework_event(self):
        repo = subject.PLATFORM
        env = {'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REPOSITORY': repo, 'CANDIDATE_REPOSITORY': repo,
               'TRUSTED_WORKFLOW_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40, 'CANDIDATE_SHA': 'a' * 40,
               'COMPANION_CANDIDATES': '[]'}
        event = {'repository': {'full_name': repo, 'visibility': 'public'},
                 'pull_request': {'head': {'repo': {'full_name': repo}}}}
        subject.scope(event, env)
        for key, value in (('GITHUB_EVENT_NAME', 'workflow_dispatch'), ('GITHUB_EVENT_NAME', 'pull_request_target'),
                           ('GITHUB_REPOSITORY', 'outside/project'), ('CANDIDATE_REPOSITORY', 'outside/project'),
                           ('TRUSTED_WORKFLOW_SHA', 'b' * 40), ('GITHUB_SHA', 'b' * 40),
                           ('COMPANION_CANDIDATES', '[{}]')):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                subject.scope(event, dict(env, **{key: value}))
        for visibility in ('private', 'internal', None):
            changed = copy.deepcopy(event); changed['repository']['visibility'] = visibility
            with self.assertRaises(ValueError): subject.scope(changed, env)
        event['pull_request']['head']['repo']['full_name'] = 'outside/fork'
        with self.assertRaises(ValueError): subject.scope(event, env)

    def test_metadata_only_then_existing_ref_validator(self):
        pr = {'number': 95, 'state': 'open', 'draft': False, 'merge_commit_sha': 'a' * 40,
              'base': {'repo': {'full_name': 'kuasar-sandbox/connector', 'private': False},
                       'sha': 'b' * 40, 'ref': 'main'}, 'head': {'sha': 'c' * 40}}
        body = '<!-- kuasar-ci-companions\nkuasar-sandbox/connector#95\n-->'
        records = subject.resolve(body, lambda endpoint: pr)
        self.assertEqual(records[0]['candidate_sha'], 'a' * 40)
        for mutation in (lambda p: p.update(draft=True), lambda p: p.update(state='closed'),
                         lambda p: p.update(merge_commit_sha=None), lambda p: p['base'].update(ref='feature'),
                         lambda p: p['base']['repo'].update(private=True)):
            changed = copy.deepcopy(pr); mutation(changed)
            with self.assertRaises(ValueError): subject.resolve(body, lambda endpoint: changed)


if __name__ == '__main__':
    unittest.main()
