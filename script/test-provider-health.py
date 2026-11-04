#!/usr/bin/env python3
"""Writer + doctor integration with synthetic homes and blocked host/network IO."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone

FIXTURES = Path(__file__).resolve().parent/'fixtures/health'
ROOT = Path(os.environ.get('HEALTH_TEST_ROOT', Path(__file__).resolve().parent.parent))
NODE = shutil.which('node')

def stamp(seconds=0):
    return datetime.fromtimestamp(time.time()+seconds, timezone.utc).isoformat()

class HealthContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.state = self.home/'.codex-usage-hud'
        self.state.mkdir(mode=0o700)
        self.guard = self.home/'guard.cjs'
        self.guard.write_text("""
const cp = require('child_process');
cp.execFileSync = (file,args) => {
  if (file === 'launchctl' && args[0] === 'print') {
    if (process.env.FAIL_GROK_JOB && args[1].endsWith('.grok-writer')) throw Error('not loaded');
    return 'state = running\\nruns = 1\\n';
  }
  throw Error('host process forbidden');
};
cp.spawn = cp.exec = cp.execSync = cp.spawnSync = () => { throw Error('process forbidden'); };
require('https').get = () => { throw Error('HTTP '+(process.env.FAKE_HTTP || '503')); };
for (const mod of ['http','net','tls']) {
  for (const key of ['request','get','connect','createConnection'])
    if (require(mod)[key]) require(mod)[key] = () => { throw Error('network forbidden'); };
}
""")
        self.env = {'PATH':f'{Path(NODE).parent}:/usr/bin:/bin', 'HOME':str(self.home),
          'CFFIXED_USER_HOME':str(self.home), 'CODEX_HOME':str(self.home/'.codex'),
          'GROK_HOME':str(self.home/'.grok'), 'CODEX_USAGE_HUD_STATE_DIR':str(self.state),
          'BLOOM_CODEX_ACCOUNT_REFRESH':'0', 'NODE_OPTIONS':'--require='+str(self.guard)}
        self.guard.write_text((FIXTURES/'guard.cjs').read_text())
        fake = self.home/'fakebin'; fake.mkdir()
        shutil.copyfile(FIXTURES/'fake-codex.js', fake/'codex'); (fake/'codex').chmod(0o755)
        self.env['FAKE_CODEX_DIR'] = str(fake)

    def write(self, rel, obj):
        p = self.home/rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj))
        return p

    def writer(self, name='grok'):
        p = subprocess.run([NODE,str(ROOT/f'bin/bloom-usage-write-{name}')], env=self.env,
            capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode,0,p.stderr)
        return json.loads((self.state/f'{name}-usage.json').read_text())

    def doctor(self):
        p = subprocess.run([NODE,str(ROOT/'bin/codex-usage-doctor'),'--json'],env=self.env,
            capture_output=True,text=True,timeout=15)
        obj = json.loads(p.stdout)
        self.assertEqual(obj['schemaVersion'],1)
        self.assertEqual(p.returncode,{'ok':0,'warn':2,'fail':1}[obj['verdict']])
        human = subprocess.run([NODE,str(ROOT/'bin/codex-usage-doctor')],env=self.env,
            capture_output=True,text=True,timeout=15)
        self.assertEqual(human.returncode,p.returncode)
        for c in obj['checks']:
            self.assertIn(c['name']+':',human.stdout)
        return obj

    def official(self):
        now = stamp(-60)
        windows = [dict(id=id,state='live',usedPct=pct,resetAt=stamp(reset),eventAt=now,capturedAt=now)
                   for id,pct,reset in [('5h',12,3600),('week',43,86400)]]
        return dict(schemaVersion=1,provider='codex',source='Codex account/rateLimits/read',
            sourceKind='official_app_server',confidence='official',eventAt=now,capturedAt=now,
            health=dict(verdict='fresh',checkedAt=now),windows=windows,
            currentSession=windows[0],week=windows[1])

    def old_event(self, date=None):
        return self.write('.codex/sessions/test.jsonl',dict(timestamp=date or stamp(-172800),
          payload=dict(rate_limits=dict(limit_id='codex',primary=dict(used_percent=90,window_minutes=300),
                                        secondary=dict(used_percent=99,window_minutes=10080)))))

    def test_unused_and_empty_directory(self):
        for empty_dir in [False,True]:
            if empty_dir: (self.home/'.grok').mkdir(exist_ok=True)
            snap=self.writer()
            self.assertEqual(snap['health']['verdict'],'not_set_up')
            self.assertEqual(snap['windows'],[])
            self.write('Library/Application Support/Codex Usage HUD/logs/grok-writer.err.log', 'sk-secret-unused')
            obj=self.doctor()
            self.assertEqual(obj['verdict'],'ok')
            self.assertFalse(any(c['name'] in ['grok writer log','com.codexusagehud.grok-writer'] for c in obj['checks']))
            self.assertNotIn('sk-secret-unused',json.dumps(obj))

    def test_existing_invalid_or_unreadable_auth(self):
        auth=self.home/'.grok/auth.json'; auth.parent.mkdir()
        for raw in ['{', '{}', '{"x":{"key":42}}', '{"x":{"key":"fixture","expires_at":"bad"}}']:
            auth.write_text(raw)
            self.assertEqual(self.writer()['health']['verdict'],'broken')
            self.assertEqual(self.doctor()['verdict'],'fail')
        auth.unlink(); auth.mkdir() # readFileSync gives EISDIR even under privileged test users
        self.assertEqual(self.writer()['health']['verdict'],'broken')
        auth.rmdir(); auth.write_text('{}'); auth.chmod(0)
        try:
            self.assertEqual(self.writer()['health']['verdict'],'broken')
        finally:
            auth.chmod(0o600)
        auth.unlink(); auth.symlink_to(auth.parent/'missing-target')
        self.assertEqual(self.writer()['health']['verdict'],'broken')

    def test_prior_bad_data_is_not_unused(self):
        for prior in ['malformed',dict(health=dict(verdict='broken'),windows=[]),
                      dict(health=dict(verdict='stale'),windows=[]),
                      dict(health=dict(verdict='not_set_up'),windows=[],providerHealth=dict(status='unauthorized'))]:
            file=self.state/'grok-usage.json'
            file.write_text(prior if isinstance(prior,str) else json.dumps(prior))
            self.assertEqual(self.writer()['health']['verdict'],'broken')

    def test_configured_unauthorized_and_helper_errors(self):
        self.write('.grok/auth.json',{'oauth':{'key':'synthetic-not-a-real-token'}})
        self.env['FAKE_HTTP']='401'
        self.assertEqual(self.writer()['health']['verdict'],'broken')
        self.assertEqual(self.doctor()['verdict'],'fail')
        self.write('Library/Application Support/Codex Usage HUD/logs/grok-writer.err.log','Bearer synthetic-secret')
        self.env['FAIL_GROK_JOB']='1'
        checks=self.doctor()['checks']
        self.assertEqual(next(c['status'] for c in checks if c['name']=='grok writer log'),'warn')
        self.assertEqual(next(c['status'] for c in checks if c['name']=='com.codexusagehud.grok-writer'),'warn')
        self.assertNotIn('synthetic-secret',json.dumps(checks))

    def test_fresh_official_supersedes_old_events_and_absent_sessions(self):
        self.write('.codex-usage-hud/codex-usage.json',self.official())
        self.assertEqual(self.doctor()['verdict'],'ok')
        self.old_event()
        self.assertEqual(self.doctor()['verdict'],'ok')

    def test_latest_poll_error_is_not_hidden_by_valid_cached_quota(self):
        self.write('.codex-usage-hud/codex-usage.json',self.official())
        self.write('Library/Application Support/Codex Usage HUD/logs/codex-writer.err.log',
                   'Codex account quota refresh failed; retaining session/cache observations.')
        self.assertEqual(self.doctor()['verdict'],'warn')

    def test_bad_official_never_suppresses_old_events(self):
        self.old_event()
        base=self.official()
        mutations=[('source','untrusted'),('sourceKind','local_session_log'),('confidence','high'),
          ('capturedAt','bad'),('capturedAt',stamp(-7200)),('capturedAt',stamp(3600)),
          ('eventAt','bad'),('eventAt',stamp(-172800)),('eventAt',stamp(3600)),('windows',[]),
          ('health',dict(verdict='broken',checkedAt=stamp())),
          ('health',dict(verdict='fresh',checkedAt='invalid')),
          ('health',dict(verdict='fresh',checkedAt=stamp(3600))),
          ('providerHealth',dict(status='unauthorized')),('officialUsageStatus',dict(status='invalid'))]
        for key,value in mutations:
            with self.subTest(key=key,value=value):
                snap=copy.deepcopy(base); snap[key]=value
                self.write('.codex-usage-hud/codex-usage.json',snap)
                self.assertNotEqual(self.doctor()['verdict'],'ok')
        for index in [0,1]:
            for key,value in [('resetAt',stamp(-1)),('eventAt',stamp(-7200)),('eventAt','bad'),
                              ('usedPct',True),('usedPct',101),('usedPct',None),('state','expired'),('resetAt','bad'),
                              ('resetAt',stamp(365*86400)),('capturedAt',stamp(3600))]:
                with self.subTest(index=index,key=key):
                    snap=copy.deepcopy(base); snap['windows'][index][key]=value
                    self.write('.codex-usage-hud/codex-usage.json',snap)
                    self.assertNotEqual(self.doctor()['verdict'],'ok')

    def test_newer_or_unknown_local_event_remains_visible(self):
        self.write('.codex-usage-hud/codex-usage.json',self.official())
        for date in [stamp(-1),'invalid',stamp(3600)]:
            self.old_event(date)
            checks=self.doctor()['checks']
            self.assertTrue(any(c['name']=='rate-limit event' for c in checks))

    def test_real_codex_writer_full_and_partial_windows(self):
        snap=self.official()
        self.write('.codex-usage-hud/codex-account-usage.json',snap)
        emitted=self.writer('codex')
        self.assertEqual(emitted['sourceKind'],'official_app_server')
        self.assertEqual(self.doctor()['verdict'],'ok')
        # Existing producer merge retains the valid local short window on a partial quota read.
        self.write('.codex/sessions/test.jsonl',dict(timestamp=stamp(-120),payload=dict(rate_limits=dict(
            limit_id='codex',primary=dict(used_percent=18,window_minutes=300,resets_at=int(time.time()+3600)),
            secondary=dict(used_percent=19,window_minutes=10080,resets_at=int(time.time()+86400))))))
        del snap['currentSession']; snap['windows']=snap['windows'][1:]
        self.write('.codex-usage-hud/codex-account-usage.json',snap)
        emitted=self.writer('codex')
        self.assertEqual(emitted['currentSession']['usedPct'],18)
        self.assertEqual(emitted['week']['usedPct'],43)
        self.assertEqual(len(emitted['windows']),2)
        self.assertEqual(self.doctor()['verdict'],'ok')


    def legacy(self, expected='broken'):
        p = subprocess.run([NODE, str(FIXTURES/'legacy-grok-writer.cjs')],
            env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stderr)
        snap = json.loads((self.state/'grok-usage.json').read_text())
        self.assertEqual(snap['health']['verdict'], expected)
        if expected == 'broken': self.assertEqual(snap['windows'], [])
        return snap

    def poll(self, mode='ok'):
        self.env.update(BLOOM_CODEX_ACCOUNT_REFRESH='1', CODEX_USAGE_HUD_MANUAL_REFRESH='1',
                        FAKE_CODEX_MODE=mode)
        return self.writer('codex')

    def test_actual_poll_no_sessions(self):
        snap = self.poll()
        self.assertEqual(snap['sourceKind'], 'official_app_server')
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_old_session(self):
        self.old_event()
        self.poll()
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_week_only_preserves_local_observation(self):
        event = stamp(-7200)
        self.write('.codex/sessions/test.jsonl', dict(timestamp=event, payload=dict(rate_limits=dict(
            limit_id='codex', primary=dict(used_percent=18, window_minutes=300, resets_at=int(time.time()+3600))))))
        snap = self.poll('weekonly')
        self.assertEqual(snap['currentSession']['usedPct'], 18)
        self.assertEqual(snap['currentSession']['eventAt'], event)
        self.assertIn('eventAt', snap['week'])
        self.assertNotEqual(snap['week']['eventAt'], event)
        # Fresh week cannot launder the retained two-hour-old local short window.
        self.assertTrue(any(c['name']=='rate-limit event' for c in self.doctor()['checks']))

    def test_actual_poll_week_only_no_sessions(self):
        snap = self.poll('weekonly')
        self.assertEqual([w['id'] for w in snap['windows']], ['week'])
        self.assertEqual(snap.get('accountQuotaCapability'), 'weekly_only')
        self.assertNotIn('currentSession', snap)
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_week_only_ancient(self):
        self.old_event()
        self.poll('weekonly')
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_corrupt_primary(self):
        snap = self.poll('corrupt')
        self.assertNotIn('accountQuotaCapability', snap)
        self.assertNotEqual(self.doctor()['verdict'], 'ok')

    def weekly_in_primary(self, mode):
        self.old_event()
        snap = self.poll(mode)
        self.assertEqual([w['id'] for w in snap['windows']], ['week'])
        self.assertEqual(snap.get('accountQuotaCapability'), 'weekly_only')
        self.assertNotIn('currentSession', snap)
        self.assertEqual(snap['week']['usedPct'], 43)
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_weekly_in_primary_null_secondary(self):
        self.weekly_in_primary('weekprimary')

    def test_actual_poll_weekly_in_primary_absent_secondary(self):
        self.weekly_in_primary('weekprimary_absent')

    def bad_extra_slot(self, mode, verdict_not_ok=True):
        self.old_event()
        snap = self.poll(mode)
        self.assertNotIn('accountQuotaCapability', snap)
        if verdict_not_ok:
            self.assertNotEqual(self.doctor()['verdict'], 'ok')
        return snap

    def test_actual_poll_weekly_primary_corrupt_secondary(self):
        self.bad_extra_slot('weekprimary_corrupt')

    def test_actual_poll_weekly_primary_empty_secondary(self):
        self.bad_extra_slot('weekprimary_empty')

    def test_actual_poll_two_weekly_slots(self):
        self.bad_extra_slot('twoweeks')

    def test_actual_poll_weekly_primary_unclassified_secondary(self):
        # A valid unlabeled extra slot falls back to the existing positional
        # 5h role; it never makes the response weekly-only.
        snap = self.bad_extra_slot('weekprimary_unknown', verdict_not_ok=False)
        self.assertIn('currentSession', snap)

    def test_actual_poll_swapped_slots_keep_two_window_rule(self):
        snap = self.poll('swapped')
        self.assertNotIn('accountQuotaCapability', snap)
        self.assertEqual(sorted(w['id'] for w in snap['windows']), ['5h', 'week'])
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_actual_poll_transition(self):
        self.poll()
        snap = self.poll('weekonly')
        self.assertNotIn('currentSession', snap)
        self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_week_only_strict_freshness_and_failures(self):
        original = self.poll('weekonly')
        for mutate in [
            lambda s: s.update(eventAt=stamp(60)),
            lambda s: s.update(capturedAt=stamp(-3600)),
            lambda s: s.update(health=dict(verdict='broken', checkedAt=stamp())),
            lambda s: s['windows'][0].update(eventAt=stamp(-3600)),
            lambda s: s['windows'][0].update(resetAt=stamp(-1)),
            lambda s: s['windows'][0].update(usedPct=150),
            lambda s: s.update(providerHealth=dict(status='unauthorized')),
            lambda s: s.update(sourceKind='local_session_log'),
        ]:
            changed = copy.deepcopy(original)
            mutate(changed)
            self.write('.codex-usage-hud/codex-usage.json', changed)
            self.assertNotEqual(self.doctor()['verdict'], 'ok')
        self.write('.codex-usage-hud/codex-usage.json', original)
        self.assertEqual(self.doctor()['verdict'], 'ok')
        self.env['FAKE_CODEX_MODE'] = 'error'
        p = subprocess.run([NODE,str(ROOT/'bin/bloom-usage-write-codex')],env=self.env,
            capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode, 0)
        self.assertIn('refresh failed', p.stderr)
        log = self.home/'Library/Application Support/Codex Usage HUD/logs/codex-writer.err.log'
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(p.stderr)
        self.assertNotEqual(self.doctor()['verdict'], 'ok')

    def test_week_only_does_not_hide_signed_out_grok(self):
        self.poll('weekonly')
        self.write('.grok/auth.json', {})
        self.assertEqual(self.writer('grok')['health']['verdict'], 'broken')
        checks = self.doctor()['checks']
        self.assertTrue(any(c['name']=='codex snapshot' and c['status']=='ok' for c in checks))
        self.assertTrue(any(c['name']=='grok health' and c['status']=='fail' for c in checks))

    def test_actual_poll_error_retains_warning(self):
        self.old_event()
        self.poll()
        self.env['FAKE_CODEX_MODE'] = 'error'
        p = subprocess.run([NODE,str(ROOT/'bin/bloom-usage-write-codex')], env=self.env,
            capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0)
        self.assertIn('quota refresh failed', p.stderr)
        log = self.home/'Library/Application Support/Codex Usage HUD/logs/codex-writer.err.log'
        log.parent.mkdir(parents=True); log.write_text(p.stderr)
        self.assertEqual(self.doctor()['verdict'], 'warn')

    def test_actual_poll_newer_local_event(self):
        self.poll()
        account = json.loads((self.state/'codex-account-usage.json').read_text())
        date = datetime.fromisoformat(account['eventAt'].replace('Z','+00:00')).timestamp()
        while time.time() <= date + .01:
            time.sleep(.01)
        newer = stamp()
        self.old_event(newer)
        checks = self.doctor()['checks']
        self.assertTrue(any(c['name']=='rate-limit event' for c in checks))
        self.env['BLOOM_CODEX_ACCOUNT_REFRESH'] = '0'
        emitted = self.writer('codex')
        self.assertEqual(emitted['eventAt'], newer)
        self.assertEqual(emitted['currentSession']['usedPct'], 90)
        self.assertNotEqual(emitted['sourceKind'], 'official_app_server')

    def test_actual_legacy_upgrade_is_quiet_repeatedly(self):
        self.legacy()
        self.assertEqual(self.doctor()['verdict'], 'ok')
        for _ in range(3):
            self.assertEqual(self.writer()['health']['verdict'], 'not_set_up')
            self.assertEqual(self.doctor()['verdict'], 'ok')

    def test_clean_and_legacy_local_records_stay_actionable(self):
        summary = self.write('.grok/sessions/project/session/summary.json',
                             dict(last_active_at=stamp(-3600),current_model_id='grok-x'))
        valid = summary.read_text()
        for legacy in [False, True]:
            for raw in [valid, '{', '']:
                with self.subTest(legacy=legacy, raw=raw):
                    (self.state/'grok-usage.json').unlink(missing_ok=True)
                    summary.write_text(raw)
                    if legacy: self.legacy()
                    for _ in range(3):
                        self.assertEqual(self.writer()['health']['verdict'], 'broken')
                        self.assertEqual(self.doctor()['verdict'], 'fail')

    def test_empty_session_directories_and_auth_override(self):
        (self.home/'.grok/sessions/project/session').mkdir(parents=True)
        self.legacy()
        self.assertEqual(self.writer()['health']['verdict'], 'not_set_up')
        self.write('.grok/auth.json', dict(oauth=dict(key='synthetic')))
        self.env['FAKE_HTTP']='403'
        self.assertEqual(self.writer()['health']['verdict'], 'broken')
        self.assertEqual(self.doctor()['verdict'], 'fail')

    def test_malformed_prior_cannot_oscillate(self):
        (self.state/'grok-usage.json').write_text('{')
        for _ in range(4):
            snap = self.writer()
            self.assertEqual(snap['health']['verdict'], 'broken')
            self.assertNotEqual(snap['health']['reason'],
                'No grok CLI auth found (~/.grok/auth.json). Run `grok login`.')
            self.assertEqual(self.doctor()['verdict'], 'fail')

    def test_legacy_contradictions_remain_actionable(self):
        legacy = self.legacy()
        for key in ['official','week','currentSession','providerHealth','officialUsageStatus','extraUsage']:
            snap = copy.deepcopy(legacy)
            snap[key] = dict(capturedAt=stamp(), products=[]) if key=='official' else {}
            self.write('.codex-usage-hud/grok-usage.json', snap)
            self.assertEqual(self.doctor()['verdict'], 'fail')
            self.assertEqual(self.writer()['health']['verdict'], 'broken')

    def test_actual_billing_survives_removed_auth(self):
        self.write('.grok/auth.json', dict(oauth=dict(key='synthetic')))
        self.env['BLOOM_GROK_BILLING_JSON']=json.dumps(dict(config=dict(
            creditUsagePercent=7,currentPeriod=dict(end=stamp(86400)),productUsage=[])))
        self.legacy('fresh')
        del self.env['BLOOM_GROK_BILLING_JSON']
        (self.home/'.grok/auth.json').unlink()
        for _ in range(3):
            snap=self.writer()
            self.assertIsNotNone(snap['official'])
            self.assertEqual(snap['health']['verdict'], 'broken')
            self.assertEqual(self.doctor()['verdict'], 'fail')


    def test_legacy_signature_is_exact(self):
        legacy = self.legacy()
        for key, value in [('schemaVersion', None), ('schemaVersion', True), ('provider', 'other'), ('source', 'unknown'),
                           ('sourceKind', 'official_api'), ('confidence', 'official'),
                           ('health', dict(verdict='broken', reason='generic failure'))]:
            with self.subTest(key=key):
                snap=copy.deepcopy(legacy); snap[key]=value
                self.write('.codex-usage-hud/grok-usage.json', snap)
                self.assertEqual(self.doctor()['verdict'], 'fail')
                for _ in range(3):
                    self.assertEqual(self.writer()['health']['verdict'], 'broken')
                    self.assertEqual(self.doctor()['verdict'], 'fail')

    def test_record_uncertainty_and_bounded_scan_stay_actionable(self):
        session = self.home/'.grok/sessions/p/s'
        session.mkdir(parents=True)
        record = session/'summary.json'
        record.symlink_to(session/'missing')
        self.assertEqual(self.writer()['health']['verdict'], 'broken')
        self.assertEqual(self.doctor()['verdict'], 'fail')
        record.unlink(); record.mkdir()
        self.assertEqual(self.writer()['health']['verdict'], 'broken')
        self.assertEqual(self.doctor()['verdict'], 'fail')
        record.rmdir()
        (self.state/'grok-usage.json').unlink()
        for i in range(501): (session/str(i)).touch()
        self.assertEqual(self.writer()['health']['verdict'], 'broken')
        self.assertEqual(self.doctor()['verdict'], 'fail')

    def test_dangling_prior_is_not_unused(self):
        (self.state/'grok-usage.json').symlink_to(self.state/'missing')
        # Existing unreadable-snapshot contract is warn until the writer
        # records an explicit broken health verdict.
        self.assertEqual(self.doctor()['verdict'], 'warn')
        self.assertTrue(any(c['name']=='grok snapshot' for c in self.doctor()['checks']))
        for _ in range(3):
            self.assertEqual(self.writer()['health']['verdict'], 'broken')
            self.assertEqual(self.doctor()['verdict'], 'fail')

if __name__=='__main__': unittest.main(verbosity=2)
