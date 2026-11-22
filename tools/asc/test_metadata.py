"""Offline tests for remote-write boundaries, retries, and screenshot reconciliation."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).with_name('metadata.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def api(apply=True):
    a = m.API.__new__(m.API)
    a.apply, a.owned, a.reads, a.writes = apply, {('apps', m.APP)}, 0, 0
    a.resources, a.bridge = {}, '/not-executed'
    return a


def response(status, body):
    return subprocess.CompletedProcess([], 0, json.dumps({'status': status, 'body': json.dumps(body), 'retryAfter': ''}), '')


class Boundaries(unittest.TestCase):
    def setUp(self):
        capture = contextlib.redirect_stdout(io.StringIO())
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def test_no_mutations_in_read_only_mode(self):
        a = api(False)
        with patch.object(m.subprocess, 'run') as run, self.assertRaises(AssertionError):
            a.request('POST', '/v1/appStoreVersions', {'data': {}})
        run.assert_not_called()

    def test_forbidden_resources_and_other_apps(self):
        a = api()
        for kind in ['appStoreVersionSubmissions', 'reviewSubmissions', 'users', 'certificates', 'betaGroups']:
            with self.assertRaises(AssertionError):
                a.guard('POST', '/v1/' + kind, {'data': {'type': kind}})
        body = {'data': {'type': 'appStoreVersions', 'attributes': {'versionString': '1.4.9'},
                         'relationships': {'app': m.relationship('apps', 'other-app')}}}
        with self.assertRaises(AssertionError):
            a.guard('POST', '/v1/appStoreVersions', body)
        with self.assertRaises(AssertionError):
            a.guard('PATCH', '/v1/appInfoLocalizations/foreign', {'data': {'type': 'appInfoLocalizations', 'id': 'foreign'}})
        with self.assertRaises(AssertionError):
            a.guard('DELETE', '/v1/builds/something', {})

    def test_bundle_mismatch_blocks_write(self):
        a = api()
        body = {'data': {'type': 'appStoreVersions', 'relationships': {'app': m.relationship('apps', m.APP)}}}
        bad_app = response(200, {'data': {'id': m.APP, 'type': 'apps', 'attributes': {'bundleId': 'wrong'}}})
        with patch.object(m.subprocess, 'run', return_value=bad_app) as run, self.assertRaises(AssertionError):
            a.request('POST', '/v1/appStoreVersions', body)
        self.assertEqual(run.call_count, 1)  # only identity GET; no POST

    def test_4xx_not_retried_and_preserves_apple_error(self):
        a = api()
        err = {'errors': [{'code': 'FORBIDDEN_ERROR', 'title': 'Forbidden', 'detail': 'Owner must accept agreement'}]}
        with patch.object(m.subprocess, 'run', return_value=response(403, err)) as run:
            with self.assertRaises(m.AppleError) as caught:
                a.request('GET', '/v1/apps/' + m.APP)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(caught.exception.errors, err['errors'])

    def test_backoff_429_and_5xx_is_finite(self):
        a = api()
        with patch.object(m.subprocess, 'run', side_effect=[response(429, {}), response(503, {}), response(200, {'data': []})]) as run, patch.object(m.time, 'sleep') as sleep:
            a.request('GET', '/v1/territories')
        self.assertEqual(run.call_count, 3)
        self.assertEqual([x.args[0] for x in sleep.call_args_list], [2, 4])
        with patch.object(m.subprocess, 'run', return_value=response(503, {})) as run, patch.object(m.time, 'sleep'):
            with self.assertRaises(m.AppleError):
                a.request('GET', '/v1/territories')
        self.assertEqual(run.call_count, 4)

    def test_post_reconciliation_recovers_completed_write(self):
        a = api()
        a.owned.add(('appScreenshotSets', 'set'))
        body = {'data': {'type': 'appScreenshots', 'attributes': {'fileName': '01.png', 'fileSize': 42},
                         'relationships': {'appScreenshotSet': m.relationship('appScreenshotSets', 'set')}}}
        shot = {'id': 'shot', 'type': 'appScreenshots', 'attributes': {'fileName': '01.png', 'fileSize': 42}}
        with patch.object(a, 'child', return_value=[shot]) as child:
            self.assertEqual(a.reconcile_create(body), shot)
        self.assertEqual(child.call_args.args[1], 'appScreenshots')

    def test_server_error_does_not_duplicate_reservation(self):
        a = api()
        a.owned.add(('appScreenshotSets', 'set'))
        body = {'data': {'type': 'appScreenshots', 'attributes': {'fileName': '01.png', 'fileSize': 42},
                         'relationships': {'appScreenshotSet': m.relationship('appScreenshotSets', 'set')}}}
        app = response(200, {'data': {'id': m.APP, 'type': 'apps', 'attributes': {'bundleId': m.BUNDLE}}})
        shot = {'id': 'shot', 'type': 'appScreenshots', 'attributes': {'fileName': '01.png', 'fileSize': 42}}
        with patch.object(m.subprocess, 'run', side_effect=[app, response(503, {})]) as run, patch.object(m.time, 'sleep'), patch.object(a, 'child', return_value=[shot]):
            recovered = a.request('POST', '/v1/appScreenshots', body)
        self.assertEqual(run.call_count, 2)  # identity GET + one POST
        self.assertEqual(recovered['data']['id'], 'shot')

    def test_owner_agreement_error_stops_without_recovery(self):
        a = api()
        sync = m.Sync(a)
        sync.exceptions = {}
        sync.first_release = True
        row = {'id': 'locale', 'type': 'appStoreVersionLocalizations', 'attributes': {'locale': 'zh-Hans'}}
        error = m.AppleError(403, [{'code': 'FORBIDDEN_ERROR', 'title': 'Forbidden', 'detail': 'Accept agreement'}])
        with patch.object(a, 'child', return_value=[row]), patch.object(a, 'patch', side_effect=error) as write:
            with self.assertRaises(m.AppleError):
                sync.localize({'id': 'version', 'type': 'appStoreVersions'}, 'appStoreVersionLocalizations',
                              'appStoreVersionLocalizations', {'zh-Hans': {'whatsNew': 'first'}}, 'Version')
        self.assertEqual(write.call_count, 1)
        self.assertEqual(sync.exceptions, {})

    def test_first_release_whatsnew_error_is_recorded_and_omitted(self):
        a = api()
        sync = m.Sync(a)
        sync.exceptions, sync.first_release = {}, True
        row = {'id': 'locale', 'type': 'appStoreVersionLocalizations', 'attributes': {'locale': 'zh-Hans'}}
        error = m.AppleError(409, [{'code': 'STATE_ERROR', 'title': 'State error',
                                  'detail': "Attribute 'whatsNew' cannot be edited at this time"}])
        with m.tempfile.TemporaryDirectory() as tmp, patch.object(m, 'REPORT', Path(tmp)), patch.object(m, 'EXCEPTIONS', Path(tmp) / 'exceptions.json'):
            with patch.object(a, 'child', return_value=[row]), patch.object(a, 'patch', side_effect=[error, row]) as write:
                sync.localize({'id': 'version', 'type': 'appStoreVersions'}, 'appStoreVersionLocalizations',
                              'appStoreVersionLocalizations', {'zh-Hans': {'description': 'description', 'whatsNew': 'first'}}, 'Version')
            self.assertEqual(write.call_count, 2)
            self.assertEqual(write.call_args.args[1], {'description': 'description'})
            self.assertEqual(json.loads((Path(tmp) / 'exceptions.json').read_text())['version.zh-Hans.whatsNew']['errors'], error.errors)

    def test_real_sources_and_limits(self):
        infos, versions, review, lengths, files = m.content()
        self.assertEqual(infos['zh-Hans']['name'], 'VoxChord 语音输入')
        self.assertEqual(infos['en-US']['name'], 'VoxChord: Voice Typing')
        self.assertIn('API key for review: <TO BE ADDED BY OWNER>', review['notes'])
        self.assertNotIn('粘贴审核', review['notes'])
        self.assertEqual(len(files['zh-Hans']), 6)
        self.assertTrue(all(x['length'] <= x['limit'] for r in lengths.values() for x in r.values()))

    def test_complete_screenshots_are_not_reuploaded(self):
        a = api()
        sync = m.Sync(a, verify=True)
        sync.facts['screenshots'] = {}
        shot_set = {'type': 'appScreenshotSets', 'id': 'set', 'attributes': {'screenshotDisplayType': m.DISPLAY}}
        rows = [{'type': 'appScreenshots', 'id': str(i), 'attributes': {'fileName': p.name,
                 'sourceFileChecksum': m.hashlib.md5(p.read_bytes()).hexdigest(), 'assetDeliveryState': {'state': 'COMPLETE'}}}
                for i, p in enumerate(sync.files['zh-Hans'])]
        with patch.object(a, 'child', side_effect=[[shot_set], rows]), patch.object(a, 'request') as request:
            sync.screenshots('zh-Hans', {'type': 'appStoreVersionLocalizations', 'id': 'locale'})
        request.assert_not_called()
        self.assertEqual(sync.pending, 0)
        self.assertEqual(len(sync.facts['screenshots']['zh-Hans']), 6)

    def test_different_screenshot_content_stops_without_overwrite(self):
        a = api()
        sync = m.Sync(a)
        shot_set = {'type': 'appScreenshotSets', 'id': 'set', 'attributes': {'screenshotDisplayType': m.DISPLAY}}
        bad = {'type': 'appScreenshots', 'id': 'shot', 'attributes': {'fileName': sync.files['zh-Hans'][0].name,
               'sourceFileChecksum': 'wrong', 'assetDeliveryState': {'state': 'COMPLETE'}}}
        with patch.object(a, 'child', side_effect=[[shot_set], [bad]]), patch.object(a, 'request') as request:
            with self.assertRaises(AssertionError):
                sync.screenshots('zh-Hans', {'type': 'appStoreVersionLocalizations', 'id': 'locale'})
        request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
