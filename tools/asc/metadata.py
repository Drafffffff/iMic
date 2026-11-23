#!/usr/bin/env python3
"""VoxChord-only ASC metadata sync. Python standard library + local CryptoKit helper."""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

if not __debug__:
    raise RuntimeError('Safety checks require Python without -O / PYTHONOPTIMIZE')

ROOT = Path(__file__).resolve().parents[2]
APP = '6829771739'
BUNDLE = 'art.malette.imic.app'
PRICE_USD = '2.99'
KEY_ID = '0N62MERQLNT3'
DISPLAY = 'APP_IPHONE_67'  # Apple's enum for the current 6.9-inch screenshot slot.
REPORT = ROOT / 'docs/appstore/asc-report'
EXCEPTIONS = REPORT / 'exceptions.json'
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'}
CREATE_PARENTS = {
    'appInfoLocalizations': ('appInfo', 'appInfos'),
    'appStoreVersions': ('app', 'apps'),
    'appStoreVersionLocalizations': ('appStoreVersion', 'appStoreVersions'),
    'appScreenshotSets': ('appStoreVersionLocalization', 'appStoreVersionLocalizations'),
    'appScreenshots': ('appScreenshotSet', 'appScreenshotSets'),
    'appStoreReviewDetails': ('appStoreVersion', 'appStoreVersions'),
    'appAvailabilities': ('app', 'apps'),
    'appPriceSchedules': ('app', 'apps'),
}
PATCH_TYPES = {'appInfoLocalizations', 'appInfos', 'ageRatingDeclarations',
               'appStoreVersions', 'appStoreVersionLocalizations', 'appScreenshots',
               'appStoreReviewDetails', 'territoryAvailabilities'}
PATCH_FIELDS = {
    'appInfoLocalizations': {'name', 'subtitle', 'privacyPolicyUrl'},
    'appInfos': set(),
    'appStoreVersions': {'versionString', 'copyright'},
    'appStoreVersionLocalizations': {'description', 'keywords', 'promotionalText', 'supportUrl', 'marketingUrl', 'whatsNew'},
    'appScreenshots': {'uploaded', 'sourceFileChecksum'},
    'appStoreReviewDetails': {'contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail', 'demoAccountRequired', 'notes'},
    'territoryAvailabilities': {'available'},
}
# All content questionnaire answers, based on Apple's OpenAPI 4.6.1.
AGE = dict.fromkeys('advertising datingAndRelationships gambling healthOrWellnessTopics lootBox '
                    'messagingAndChat parentalControls ageAssurance sharedLocation socialMedia '
                    'socialMediaAgeRestricted unrestrictedWebAccess userGeneratedContent'.split(), False)
AGE.update(dict.fromkeys('alcoholTobaccoOrDrugUseOrReferences contests gamblingSimulated gunsOrOtherWeapons '
                         'medicalOrTreatmentInformation profanityOrCrudeHumor sexualContentGraphicAndNudity '
                         'sexualContentOrNudity horrorOrFearThemes matureOrSuggestiveThemes violenceCartoonOrFantasy '
                         'violenceRealisticProlongedGraphicOrSadistic violenceRealistic '
                         'ageRatingOverrideV2 koreaAgeRatingOverride'.split(), 'NONE'))
PATCH_FIELDS['ageRatingDeclarations'] = set(AGE)


class AppleError(RuntimeError):
    def __init__(self, status, errors):
        self.status, self.errors = status, errors
        super().__init__(f'HTTP {status}: ' + json.dumps(errors, ensure_ascii=False))


def short(value):
    if isinstance(value, str) and len(value) > 40:
        return json.dumps(value[:40], ensure_ascii=False) + f'… (length={len(value)})'
    return json.dumps(value, ensure_ascii=False)


def relationship(kind, ident):
    return {'data': {'type': kind, 'id': ident}}


def attrs(row):
    return row.get('attributes', {}) if row else {}


def field_evidence(row, fields):
    """Keep full-string comparison auditable without storing long review text."""
    result = {}
    for field in fields:
        value = attrs(row).get(field)
        result[field] = {'length': len(value), 'sha256': hashlib.sha256(value.encode()).hexdigest()} if isinstance(value, str) and len(value) > 40 else value
    return result


def content():
    assert (ROOT / 'VERSION').read_text().strip() == '1.4.9', 'Task is limited to 1.4.9'
    listing = (ROOT / 'docs/appstore/listing.md').read_text()
    review = (ROOT / 'docs/appstore/review.md').read_text()
    def section(heading):
        return listing.split('## ' + heading + '\n', 1)[1].split('\n## ', 1)[0].strip()
    def table(field):
        line = next(x for x in listing.splitlines() if x.startswith('| ' + field + ' |'))
        return [re.sub(r'（\d+）$', '', x.strip()) for x in line.split('|')[2:4]]
    names, subtitles = table('名称（≤30）'), table('副标题（≤30）')
    privacy = table('隐私政策网址')[0]
    keys = re.findall(r'`([^`]+)`', section('关键词（≤100，逗号分隔、不加空格）'))
    promo = section('推广文本（≤170，可随时修改，无需审核）').splitlines()
    news = section("此版本新增（What's New，首发可用）").splitlines()
    infos, versions = {}, {}
    for i, locale in enumerate(('zh-Hans', 'en-US')):
        infos[locale] = dict(name=names[i], subtitle=subtitles[i], privacyPolicyUrl=privacy)
        url = table('支持网址')[i]
        versions[locale] = dict(description=section('描述（中文）' if i == 0 else 'Description (English)'),
                                keywords=keys[i], promotionalText=promo[i].split('：' if i == 0 else ': ', 1)[1],
                                supportUrl=url, marketingUrl=table('营销网址')[i],
                                whatsNew=news[i].split('：' if i == 0 else ': ', 1)[1])
    notes = review.split('```\n', 1)[1].split('\n```', 1)[0]
    notes = re.sub(r'API key for review: [^\n]*', 'API key for review: <TO BE ADDED BY OWNER>', notes)
    assert notes.count('API key for review: <TO BE ADDED BY OWNER>') == 1
    contact = dict(contactFirstName='龙飞', contactLastName='周', contactPhone='+86 13818611371',
                   contactEmail='i0.0ia@qq.com', demoAccountRequired=False, notes=notes)
    lengths = {}
    for locale in infos:
        lengths[locale] = {}
        for field, limit in dict(name=30, subtitle=30, promotionalText=170, keywords=100, description=4000).items():
            value = (infos[locale] | versions[locale])[field]
            assert len(value) <= limit, f'{locale}.{field} exceeds {limit}'
            lengths[locale][field] = {'length': len(value), 'limit': limit}
    shots = {}
    for locale, directory in [('zh-Hans', 'zh-Hans'), ('en-US', 'en')]:
        shots[locale] = sorted((ROOT / 'docs/appstore/screenshots' / directory).glob('*.png'))
        assert len(shots[locale]) == 6, f'{locale}: expected six screenshots'
        for path in shots[locale]:
            data = path.read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            assert struct.unpack('>II', data[16:24]) == (1320, 2868)
            assert data[25] in (0, 2, 3), f'{path.name}: alpha channel is not supported'
    return infos, versions, contact, lengths, shots


class API:
    def __init__(self, apply=False):
        self.apply = apply
        self.owned = {('apps', APP)}
        self.writes = 0
        self.reads = 0
        self.resources = {}
        self.tmp = tempfile.TemporaryDirectory(prefix='voxchord-asc-')
        self.bridge = str(Path(self.tmp.name) / 'request')
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(Path(__file__).with_name('request.swift')),
                                 '-o', self.bridge], capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError('Failed to compile local CryptoKit request helper')

    def request(self, method, path, body=None, missing=False):
        assert path.startswith('/v') and '://' not in path
        if method != 'GET':
            assert self.apply, 'Read-only mode forbids mutations'
            self.guard(method, path, body)
        request = dict(method=method, path=path)
        if body is not None:
            request['body'] = body
        for attempt in range(4):
            if method != 'GET':
                # Includes retry attempts, not just the first write.
                app = self.request('GET', f'/v1/apps/{APP}')["data"]
                assert app['id'] == APP and attrs(app)['bundleId'] == BUNDLE, 'App identity mismatch; stopped'
            # The Swift child emits only response data; JWT never leaves that process.
            result = subprocess.run([self.bridge], input=json.dumps(request), text=True,
                                    capture_output=True, timeout=75)
            if result.returncode:
                # An ambiguous write is never blindly replayed after a transport failure.
                raise RuntimeError('Local credential/signing/transport failure; rerun dry-run to reconcile')
            response = json.loads(result.stdout)
            status = response['status']
            try:
                parsed = json.loads(response['body']) if response['body'] else {}
            except json.JSONDecodeError:
                if 200 <= status < 300:
                    raise RuntimeError('Malformed JSON API response; stopped') from None
                parsed = {'errors': [{'code': f'HTTP_{status}', 'title': 'Non-JSON API response', 'detail': 'Response body withheld'}]}
            if status == 429 or status >= 500:
                if attempt < 3:
                    retry_after = response['retryAfter']
                    delay = min(30, max(2 ** (attempt + 1), int(retry_after) if retry_after.isdigit() else 0))
                    print(f'HTTP {status}; backoff {delay}s ({attempt + 1}/3)', flush=True)
                    time.sleep(delay)
                    if method == 'POST':
                        recovered = self.reconcile_create(body)
                        if recovered:
                            print(f'{recovered["type"]}: recovered existing resource before retry', flush=True)
                            self.writes += 1
                            return {'data': recovered}
                    continue
            if not 200 <= status < 300:
                errors = [{k: x.get(k, '') for k in ('code', 'title', 'detail')} for x in parsed.get('errors', [])]
                error = AppleError(status, errors)
                if status == 404 and missing:
                    print(f'Absent optional resource {path.split("?")[0]}: {error}', flush=True)
                    return {'data': None}
                raise error
            if method == 'GET':
                self.reads += 1
            else:
                self.writes += 1
            rows = parsed.get('data') or []
            for row in (rows if isinstance(rows, list) else [rows]) + parsed.get('included', []):
                if isinstance(row, dict) and 'id' in row and 'type' in row:
                    self.resources[(row['type'], row['id'])] = row
            return parsed
        raise RuntimeError('Retry budget exhausted')

    def reconcile_create(self, body):
        """A server error may follow a successful POST. Read before replaying it."""
        data = body['data']
        kind = data['type']
        relation, parent_type = CREATE_PARENTS[kind]
        parent = data['relationships'][relation]['data']
        assert (parent_type, parent['id']) in self.owned
        names = {'appInfoLocalizations': 'appInfoLocalizations',
                 'appStoreVersions': 'appStoreVersions',
                 'appStoreVersionLocalizations': 'appStoreVersionLocalizations',
                 'appScreenshotSets': 'appScreenshotSets', 'appScreenshots': 'appScreenshots',
                 'appStoreReviewDetails': 'appStoreReviewDetail',
                 'appAvailabilities': 'appAvailabilityV2', 'appPriceSchedules': 'appPriceSchedule'}
        many = kind not in {'appStoreReviewDetails', 'appAvailabilities', 'appPriceSchedules'}
        rows = self.child(parent, names[kind], many=many, missing=True)
        rows = rows if many else [rows] if rows else []
        expected = data.get('attributes', {})
        matches = [r for r in rows if all(attrs(r).get(k) == v for k, v in expected.items())]
        if kind == 'appPriceSchedules' and matches:
            prices = self.child(matches[0], 'manualPrices', many=True, missing=True,
                                query={'include': 'appPricePoint', 'limit': '200'})
            wanted = body['included'][0]['relationships']['appPricePoint']['data']['id']
            matches = matches if any(p['relationships']['appPricePoint']['data']['id'] == wanted for p in prices) else []
        assert len(matches) <= 1, 'Ambiguous POST recovery; stopped'
        return matches[0] if matches else None

    def guard(self, method, path, body):
        parts = path.split('/')
        kind = parts[2]
        data = body.get('data')
        if method == 'POST':
            assert kind in CREATE_PARENTS and len(parts) == 3
            assert data['type'] == kind
            rel, parent_type = CREATE_PARENTS[kind]
            parent = data['relationships'][rel]['data']
            assert parent['type'] == parent_type and (parent_type, parent['id']) in self.owned
            # Every create has exactly one app-owned parent; no arbitrary nested app targets.
            extra = {'baseTerritory', 'manualPrices'} if kind == 'appPriceSchedules' else {'territoryAvailabilities'} if kind == 'appAvailabilities' else set()
            assert set(data['relationships']) == {rel} | extra
            if kind in ('appAvailabilities', 'appPriceSchedules'):
                assert parent['id'] == APP
            if kind == 'appPriceSchedules':
                assert data['relationships']['baseTerritory'] == relationship('territories', 'USA')
                for included in body['included']:
                    point = included['relationships']['appPricePoint']['data']
                    assert (point['type'], point['id']) in self.owned and point['type'] == 'appPricePoints'
        elif method == 'PATCH' and len(parts) == 4:
            assert kind in PATCH_TYPES and data['type'] == kind and data['id'] == parts[3]
            assert (kind, parts[3]) in self.owned, 'Unverified resource ownership'
            assert set(data.get('attributes', {})) <= PATCH_FIELDS[kind]
            if kind == 'appInfos':
                assert set(data.get('relationships', {})) <= {'primaryCategory', 'secondaryCategory'}
                for field, value in data.get('relationships', {}).items():
                    assert value == relationship('appCategories', 'PRODUCTIVITY' if field == 'primaryCategory' else 'UTILITIES')
            elif kind != 'appStoreVersions':
                assert 'relationships' not in data
            if kind == 'appStoreVersions' and 'relationships' in data:
                assert set(data['relationships']) == {'build'}
                b = data['relationships']['build']['data']
                assert (b['type'], b['id']) in self.owned and b['type'] == 'builds'
        elif method == 'PATCH' and len(parts) == 6:
            assert kind == 'appScreenshotSets' and parts[4:] == ['relationships', 'appScreenshots']
            assert (kind, parts[3]) in self.owned
            assert all(x['type'] == 'appScreenshots' and ('appScreenshots', x['id']) in self.owned for x in data)
        else:
            raise AssertionError('Mutation outside the metadata allowlist')

    def child(self, parent, relation, many=False, missing=False, query=None, version='v1'):
        assert (parent['type'], parent['id']) in self.owned
        path = f'/{version}/{parent["type"]}/{parent["id"]}/{relation}'
        if query:
            path += '?' + urllib.parse.urlencode(query)
        result = self.request('GET', path, missing=missing)
        rows = result.get('data') or ([] if many else None)
        if many:
            while result.get('links', {}).get('next'):
                url = urllib.parse.urlsplit(result['links']['next'])
                assert url.scheme == 'https' and url.netloc == 'api.appstoreconnect.apple.com'
                assert url.path == path.split('?')[0], 'Unexpected pagination target'
                result = self.request('GET', url.path + '?' + url.query)
                rows.extend(result['data'])
        for row in rows if many else [rows] if rows else []:
            self.owned.add((row['type'], row['id']))
        return rows

    def create(self, kind, attributes, parent, relation, extra=None, included=None):
        data = dict(type=kind, attributes=attributes, relationships={relation: relationship(parent['type'], parent['id'])})
        if not attributes:
            data.pop('attributes')
        if extra:
            data['relationships'].update(extra)
        body = {'data': data}
        if included:
            body['included'] = included
        version = 'v2' if kind == 'appAvailabilities' else 'v1'
        row = self.request('POST', f'/{version}/{kind}', body)['data']
        self.owned.add((row['type'], row['id']))
        return row

    def patch(self, row, changes=None, relations=None):
        data = dict(type=row['type'], id=row['id'])
        if changes:
            data['attributes'] = changes
        if relations:
            data['relationships'] = relations
        result = self.request('PATCH', f'/v1/{row["type"]}/{row["id"]}', {'data': data})
        return result.get('data', row)


class Sync:
    def __init__(self, api, verify=False):
        self.api, self.verify = api, verify
        self.pending = 0
        self.facts = {}
        self.first_release = False
        self.exceptions = json.loads(EXCEPTIONS.read_text()) if EXCEPTIONS.exists() else {}
        self.infos, self.versions, self.contact, self.lengths, self.files = content()

    def change(self, label, old, new):
        if old != new:
            self.pending += 1
            print(f'{label}: {short(old)} → {short(new)}', flush=True)
            return True
        print(f'{label}: {short(old)} (unchanged)', flush=True)
        return False

    def update(self, row, desired, label):
        changes = {k: v for k, v in desired.items() if self.change(f'{label}.{k}', attrs(row).get(k), v)}
        if changes and self.api.apply:
            return self.api.patch(row, changes)
        return row

    def localize(self, parent, relation, kind, desired, label):
        rows = self.api.child(parent, relation, many=True) if parent else []
        result = {}
        for locale, fields in desired.items():
            matches = [r for r in rows if attrs(r)['locale'] == locale]
            assert len(matches) <= 1, f'Duplicate {label}.{locale}'
            row = matches[0] if matches else None
            values = dict(fields)
            if kind == 'appInfoLocalizations':
                fallback = {'zh-Hans': 'VoxChord 语音键', 'en-US': 'VoxChord: Hold to Dictate'}[locale]
                if attrs(row).get('name') == fallback:
                    values['name'] = fallback
            skip = self.exceptions.get(f'{parent["id"] if parent else "new"}.{locale}.whatsNew')
            if skip:
                assert self.first_release and skip['field'] == 'whatsNew' and skip['errors']
                assert all(e['code'] == 'STATE_ERROR' and e['detail'] == "Attribute 'whatsNew' cannot be edited at this time" for e in skip['errors'])
                print(f'{label}.{locale}.whatsNew: skipped; Apple rejection recorded', flush=True)
                values.pop('whatsNew', None)
            changes = {k: v for k, v in values.items() if self.change(f'{label}.{locale}.{k}', attrs(row).get(k), v)}
            if changes and self.api.apply:
                def write():
                    if row:
                        return self.api.patch(row, changes)
                    return self.api.create(kind, dict(locale=locale, **values), parent,
                                           'appInfo' if kind == 'appInfoLocalizations' else 'appStoreVersion')
                try:
                    row = write()
                except AppleError as error:
                    details = json.dumps(error.errors).lower()
                    print(f'{label}.{locale}: {error}', flush=True)
                    if kind == 'appInfoLocalizations' and 'name' in changes and ('already' in details or 'used' in details) and 'name' in details:
                        values['name'] = changes['name'] = fallback
                        print(f'{label}.{locale}.name: fallback → {fallback}', flush=True)
                        row = write()
                    elif ('whatsNew' in changes and self.first_release and error.status == 409
                          and all(e['code'] == 'STATE_ERROR' and e['detail'] == "Attribute 'whatsNew' cannot be edited at this time"
                                  for e in error.errors) and error.errors):
                        self.exceptions[f'{parent["id"]}.{locale}.whatsNew'] = dict(field='whatsNew', errors=error.errors)
                        REPORT.mkdir(exist_ok=True)
                        EXCEPTIONS.write_text(json.dumps(self.exceptions, ensure_ascii=False, indent=2) + '\n')
                        values.pop('whatsNew', None)
                        changes.pop('whatsNew', None)
                        row = write()
                    else:
                        # Agreements or any new owner decisions stop execution here.
                        raise
            result[locale] = row
        return result

    def run(self):
        app = self.api.request('GET', f'/v1/apps/{APP}')['data']
        assert app['id'] == APP and attrs(app)['bundleId'] == BUNDLE
        assert attrs(app)['primaryLocale'] == 'zh-Hans', 'Primary locale mismatch; stopped'
        print(f'Identity verified: App {APP}, bundleId {BUNDLE}, primaryLocale zh-Hans; Key ID {KEY_ID}', flush=True)
        print('Field lengths: ' + json.dumps(self.lengths, ensure_ascii=False), flush=True)
        infos = self.api.child(app, 'appInfos', many=True)
        editable = [r for r in infos if attrs(r).get('state', attrs(r).get('appStoreState')) in EDITABLE]
        assert len(editable) == 1, 'Expected one editable appInfo'
        info = editable[0]
        info_locs = self.localize(info, 'appInfoLocalizations', 'appInfoLocalizations', self.infos, 'AppInfo')
        if self.verify:
            self.facts['appInfoLocalizations'] = {locale: field_evidence(row, self.infos[locale]) for locale, row in info_locs.items()}
        for field, category in [('primaryCategory', 'PRODUCTIVITY'), ('secondaryCategory', 'UTILITIES')]:
            current = self.api.child(info, field, missing=True)
            if self.change(field, current['id'] if current else None, category) and self.api.apply:
                self.api.patch(info, relations={field: relationship('appCategories', category)})
        age = self.api.child(info, 'ageRatingDeclaration')
        assert age
        self.update(age, AGE, 'AgeRating')
        if self.verify:
            current_info = self.api.request('GET', f'/v1/appInfos/{info["id"]}')['data']
            self.facts['ageRating'] = attrs(current_info)
            assert attrs(current_info)['appStoreAgeRating'] == 'FOUR_PLUS', 'Expected 4+ age rating'
        self.prices(app)
        self.availability(app)
        version_number = (ROOT / 'VERSION').read_text().strip()
        assert version_number == '1.4.9', 'Task is limited to 1.4.9'
        versions = self.api.child(app, 'appStoreVersions', many=True)
        self.first_release = not versions or (len(versions) == 1 and attrs(versions[0]).get('appVersionState') == 'PREPARE_FOR_SUBMISSION')
        candidates = [v for v in versions if attrs(v)['platform'] == 'IOS' and attrs(v).get('appVersionState', attrs(v).get('appStoreState')) in EDITABLE]
        assert len(candidates) <= 1, 'Multiple editable versions; stopped'
        version = candidates[0] if candidates else None
        if not version:
            self.change('Version', None, version_number)
            if self.api.apply:
                version = self.api.create('appStoreVersions', dict(platform='IOS', versionString=version_number,
                                          copyright='2026 KE CHENG'), app, 'app')
        else:
            version = self.update(version, dict(versionString=version_number, copyright='2026 KE CHENG'), 'Version')
        build_query = {'filter[app]': APP, 'filter[preReleaseVersion.version]': version_number,
                       'filter[preReleaseVersion.platform]': 'IOS', 'filter[processingState]': 'VALID',
                       'filter[expired]': 'false', 'filter[buildAudienceType]': 'APP_STORE_ELIGIBLE',
                       'sort': '-uploadedDate', 'limit': '200'}
        builds = self.api.request('GET', '/v1/builds?' + urllib.parse.urlencode(build_query))['data']
        builds = [b for b in builds if not attrs(b)['expired'] and attrs(b).get('buildAudienceType') == 'APP_STORE_ELIGIBLE']
        build = builds[0] if builds else None
        self.facts['build'] = {'id': build['id'], **{k: attrs(build)[k] for k in ('version', 'processingState', 'uploadedDate', 'usesNonExemptEncryption')}} if build else None
        if build:
            # Independently verify the selected build belongs to this app and release.
            self.api.owned.add(('builds', build['id']))
            build_app = self.api.child(build, 'app')
            assert build_app['id'] == APP and attrs(build_app)['bundleId'] == BUNDLE
            prerelease = self.api.child(build, 'preReleaseVersion')
            assert attrs(prerelease)['version'] == version_number and attrs(prerelease)['platform'] == 'IOS'
            current = self.api.child(version, 'build', missing=True) if version else None
            if self.change('Version.build', current['id'] if current else None, build['id']) and self.api.apply:
                self.api.patch(version, relations={'build': relationship('builds', build['id'])})
        else:
            print('Version.build: SKIPPED; no processed eligible 1.4.9 build; no upload', flush=True)
        locs = self.localize(version, 'appStoreVersionLocalizations', 'appStoreVersionLocalizations', self.versions, 'VersionLocalization')
        if self.verify:
            self.facts['versionLocalizations'] = {locale: field_evidence(row, self.versions[locale]) for locale, row in locs.items()}
        self.facts['screenshots'] = {}
        for locale, row in locs.items():
            self.screenshots(locale, row)
        review = self.api.child(version, 'appStoreReviewDetail', missing=True) if version else None
        changes = {k: v for k, v in self.contact.items() if self.change(f'Review.{k}', attrs(review).get(k), v)}
        if changes and self.api.apply:
            if review:
                self.api.patch(review, changes)
            else:
                self.api.create('appStoreReviewDetails', self.contact, version, 'appStoreVersion')
        if self.verify:
            assert attrs(review) == (attrs(review) | self.contact), 'Review mismatch'
            assert '<TO BE ADDED BY OWNER>' in attrs(review)['notes']
            assert not attrs(review).get('demoAccountName') and not attrs(review).get('demoAccountPassword')
            self.facts['review'] = field_evidence(review, self.contact)
        self.facts.update(appId=APP, bundleId=BUNDLE, versionId=version['id'] if version else None,
                          versionState=attrs(version).get('appVersionState'),
                          fieldLengths=self.lengths, pending=self.pending, writes=self.api.writes,
                          reads=self.api.reads, exceptions=self.exceptions)
        print(f'RESULT: pending={self.pending}, writes={self.api.writes}, reads={self.api.reads}', flush=True)
        if self.verify:
            assert self.pending == 0, 'Verification found pending changes'
            print('VERIFIED: all metadata fields, locale strings, age rating, pricing, territories, selected build, review, screenshot order/checksums/COMPLETE', flush=True)
        return self.facts

    def prices(self, app):
        # Owner decision 2026-11-23: USD 2.99 in base territory USA; other territories use Apple's automatic prices.
        schedule = self.api.child(app, 'appPriceSchedule', missing=True)
        prices = self.api.child(schedule, 'manualPrices', many=True, missing=True,
                                query={'include': 'appPricePoint,territory', 'limit': '200'}) if schedule else []
        # ASC may return an empty schedule shell before its first price is set.
        points = []
        automatic = self.api.child(schedule, 'automaticPrices', many=True,
                                   query={'include': 'appPricePoint,territory', 'limit': '200'}) if prices else []
        manual = []
        for price in prices + automatic:
            point_id = price['relationships']['appPricePoint']['data']['id']
            point = self.api.resources.get(('appPricePoints', point_id))
            if point is None:
                point = self.api.request('GET', f'/v3/appPricePoints/{point_id}')['data']
            points.append(attrs(point)['customerPrice'])
            if price in prices:
                manual.append((price['relationships']['territory']['data']['id'], attrs(point)['customerPrice']))
        if prices:
            assert all(t == 'USA' and float(p) == float(PRICE_USD) for t, p in manual), \
                f'Existing price plan {manual} differs from USD {PRICE_USD}; do not overwrite pricing'
            print(f'Price: USD {PRICE_USD} (unchanged), {len(prices)} manual + {len(automatic)} automatic prices', flush=True)
            self.facts['price'] = {'baseTerritory': 'USA', 'customerPriceUSD': PRICE_USD,
                                  'manualCount': len(prices), 'automaticCount': len(automatic)}
            return
        self.change('Price', None, f'USD {PRICE_USD} (base territory USA)')
        points = self.api.child(app, 'appPricePoints', many=True,
                                query={'filter[territory]': 'USA', 'limit': '200'})
        target = next(p for p in points if float(attrs(p)['customerPrice']) == float(PRICE_USD))
        if self.api.apply:
            self.api.create('appPriceSchedules', {}, app, 'app',
                            extra={'baseTerritory': relationship('territories', 'USA'),
                                   'manualPrices': {'data': [{'type': 'appPrices', 'id': '${price}'}]}},
                            included=[dict(type='appPrices', id='${price}', attributes={'startDate': None, 'endDate': None},
                                           relationships={'appPricePoint': relationship('appPricePoints', target['id'])})])

    def availability(self, app):
        territories = self.api.request('GET', '/v1/territories?limit=200')['data']
        assert len(territories) < 200, 'Territory pagination needs review'
        desired = {r['id'] for r in territories} - {'CHN'}
        available = self.api.child(app, 'appAvailabilityV2', missing=True)
        rows = self.api.child(available, 'territoryAvailabilities', many=True, version='v2',
                              query={'include': 'territory', 'limit': '200'}) if available else []
        mapping = {}
        for row in rows:
            terr = row['relationships']['territory']['data']['id']
            mapping[terr] = row
        current = {k for k, r in mapping.items() if attrs(r)['available']}
        self.change('Territories.count', len(current), len(desired))
        self.change('Territories.excluded', sorted(set(r['id'] for r in territories) - current), ['CHN'])
        new_auto = attrs(available).get('availableInNewTerritories')
        auto_change = self.change('Territories.availableInNewTerritories', new_auto, True)
        if not available or auto_change:
            if self.api.apply:
                included = [dict(type='territoryAvailabilities', id='${' + t + '}', attributes={'available': t in desired},
                                 relationships={'territory': relationship('territories', t)}) for t in sorted(desired | {'CHN'})]
                self.api.create('appAvailabilities', {'availableInNewTerritories': True}, app, 'app',
                                extra={'territoryAvailabilities': {'data': [{'type': r['type'], 'id': r['id']} for r in included]}},
                                included=included)
        else:
            assert set(mapping) == desired | {'CHN'}, 'Incomplete territory coverage'
            for territory, row in sorted(mapping.items()):
                target = territory in desired
                if attrs(row)['available'] != target:
                    self.change(f'Territory.{territory}', attrs(row)['available'], target)
                    if self.api.apply:
                        self.api.patch(row, {'available': target})
        if self.verify:
            assert current == desired and new_auto is True
            self.facts['territories'] = sorted(current)
            self.facts['availableInNewTerritories'] = new_auto
            self.facts['territoryCount'] = len(current)

    def screenshots(self, locale, localization):
        sets = self.api.child(localization, 'appScreenshotSets', many=True) if localization else []
        matches = [r for r in sets if attrs(r)['screenshotDisplayType'] == DISPLAY]
        assert len(matches) <= 1
        shot_set = matches[0] if matches else None
        if not shot_set:
            self.change(f'Screenshots.{locale}.set', None, DISPLAY)
            if self.api.apply:
                shot_set = self.api.create('appScreenshotSets', {'screenshotDisplayType': DISPLAY},
                                            localization, 'appStoreVersionLocalization')
        rows = self.api.child(shot_set, 'appScreenshots', many=True) if shot_set else []
        assert len({attrs(r)['fileName'] for r in rows}) == len(rows), 'Duplicate screenshot names'
        by_name = {attrs(r)['fileName']: r for r in rows}
        expected_names = [p.name for p in self.files[locale]]
        assert set(by_name) <= set(expected_names), 'Existing unknown screenshots; no deletion authorized'
        ordered, facts = [], []
        for path in self.files[locale]:
            data = path.read_bytes()
            md5 = hashlib.md5(data).hexdigest()
            shot = by_name.get(path.name)
            state = attrs(shot).get('assetDeliveryState', {}).get('state')
            checksum = attrs(shot).get('sourceFileChecksum')
            if checksum:
                assert checksum.lower() == md5, f'{locale}/{path.name}: checksum differs; stopped'
            if state == 'COMPLETE':
                assert checksum and checksum.lower() == md5, f'{locale}/{path.name}: missing checksum; stopped'
            if state != 'COMPLETE':
                self.change(f'Screenshots.{locale}.{path.name}', state, 'COMPLETE')
                if self.api.apply:
                    if not shot:
                        shot = self.api.create('appScreenshots', {'fileName': path.name, 'fileSize': len(data)},
                                               shot_set, 'appScreenshotSet')
                    state = attrs(shot).get('assetDeliveryState', {}).get('state')
                    if state in ('AWAITING_UPLOAD', 'UPLOAD_COMPLETE', None):
                        if state != 'UPLOAD_COMPLETE':
                            operations = attrs(shot).get('uploadOperations') or []
                            assert operations, 'Missing screenshot upload operations'
                            for op in operations:
                                self.upload(op, data)
                        self.api.patch(shot, {'uploaded': True, 'sourceFileChecksum': md5})
                    shot = self.poll(shot)
                    state = attrs(shot)['assetDeliveryState']['state']
            else:
                print(f'Screenshots.{locale}.{path.name}: COMPLETE, MD5 {md5} (unchanged)', flush=True)
            if shot:
                ordered.append({'type': 'appScreenshots', 'id': shot['id']})
                facts.append(dict(fileName=path.name, id=shot['id'], state=state, md5=md5))
        if shot_set:
            old_order = [{'type': r['type'], 'id': r['id']} for r in rows]
            # New screenshot resources are appended in the required order by ASC.
            if len(rows) == 6 and old_order != ordered:
                self.change(f'Screenshots.{locale}.order', [attrs(r)['fileName'] for r in rows], expected_names)
                if self.api.apply:
                    self.api.request('PATCH', f'/v1/appScreenshotSets/{shot_set["id"]}/relationships/appScreenshots', {'data': ordered})
            if self.verify:
                assert len(rows) == 6 and old_order == ordered
                assert all(r['state'] == 'COMPLETE' for r in facts)
        elif self.verify:
            raise AssertionError('Missing screenshot set')
        self.facts['screenshots'][locale] = facts

    def upload(self, op, data):
        assert self.api.apply
        url = urllib.parse.urlsplit(op['url'])
        assert url.scheme == 'https' and url.hostname and (url.hostname.endswith('.apple.com') or url.hostname.endswith('.icloud-content.com')), 'Unexpected upload host'
        assert op['method'] == 'PUT'
        headers = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
        assert not any(k.lower() == 'authorization' for k in headers), 'Unexpected upload authorization header'
        offset, length = op['offset'], op['length']
        chunk = data[offset:offset + length]
        assert len(chunk) == length
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                return None
        opener = urllib.request.build_opener(NoRedirect())
        for attempt in range(4):
            # Recheck before every PUT, including retries; never send an ASC JWT to storage.
            app = self.api.request('GET', f'/v1/apps/{APP}')['data']
            assert app['id'] == APP and attrs(app)['bundleId'] == BUNDLE
            try:
                request = urllib.request.Request(op['url'], data=chunk, headers=headers, method='PUT')
                with opener.open(request, timeout=60) as response:
                    assert 200 <= response.status < 300
                print(f'Screenshot PUT: offset={offset}, length={length}, success', flush=True)
                return
            except urllib.error.HTTPError as error:
                if (error.code == 429 or error.code >= 500) and attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise RuntimeError(f'Screenshot PUT failed: HTTP {error.code}; signed URL withheld') from None
            except (urllib.error.URLError, TimeoutError):
                raise RuntimeError('Screenshot PUT transport failure; signed URL withheld') from None

    def poll(self, shot):
        for _ in range(60):
            current = self.api.request('GET', f'/v1/appScreenshots/{shot["id"]}')['data']
            state = attrs(current)['assetDeliveryState']['state']
            if state == 'COMPLETE':
                print(f'Screenshot {attrs(current)["fileName"]}: COMPLETE', flush=True)
                return current
            if state == 'FAILED':
                raise RuntimeError('Screenshot processing failed: ' + json.dumps(attrs(current)['assetDeliveryState'].get('errors', [])))
            time.sleep(5)
        raise RuntimeError('Screenshot processing timed out; rerun dry-run to reconcile')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--dry-run', action='store_true', help='GET only; print field differences')
    mode.add_argument('--apply', action='store_true', help='Apply only allowlisted metadata to VoxChord')
    mode.add_argument('--verify', action='store_true', help='GET only; fail on any field or asset mismatch')
    parser.add_argument('--json-report', type=Path, help='Write filtered verification facts (no credentials)')
    args = parser.parse_args()
    start = time.monotonic()
    try:
        api = API(apply=args.apply)
        facts = Sync(api, verify=args.verify).run()
        facts['elapsedSeconds'] = round(time.monotonic() - start, 2)
        if args.json_report:
            args.json_report.write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')
        print(f'Elapsed: {facts["elapsedSeconds"]} seconds', flush=True)
    except (AppleError, AssertionError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'STOPPED: {error}', file=sys.stderr, flush=True)
        print(f'Elapsed before stop: {time.monotonic() - start:.2f} seconds', file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
