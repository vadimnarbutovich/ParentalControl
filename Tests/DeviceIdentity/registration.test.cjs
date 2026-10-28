const assert = require('node:assert/strict');
const test = require('node:test');
const { readFileSync } = require('node:fs');
const source = readFileSync(new URL('../../supabase/functions/parental-control-sync/index.ts', 'file://' + __filename), 'utf8');
const body = source.slice(source.indexOf('async function registerDevice('), source.indexOf('async function generatePairingCode('))
  .replace('req: Request, payload: Json): Promise<Response>', 'req, payload)');
const secret = 'a'.repeat(64);
const existing = { id: 'old-device', device_secret: secret, role: 'child', family_id: null };
async function register(record, role, { conflict = false, suppliedSecret = secret, changeError = null, inspectOnly = false } = {}) {
  const writes = [];
  const filters = [];
  const db = {
    from(table) {
      assert.equal(table, 'devices', 'Registration must not reset demo/purchase tables');
      let update;
      return {
        select() { return this; },
        eq(k, v) { filters.push([k, v]); return this; },
        is(k, v) { filters.push([k, v]); return this; },
        update(value) { update = value; writes.push({ update: value }); return this; },
        async insert(value) { writes.push({ insert: value }); return { error: null }; },
        async maybeSingle() {
          return update ? { data: conflict ? null : { id: record.id }, error: changeError }
            : { data: record, error: null };
        }
      };
    }
  };
  const handler = new Function('supabase', 'asString', 'errorResponse', 'okResponse', 'fetchPairingState',
    body + '; return registerDevice;')(db, x => typeof x === 'string' ? x : '',
      (message, status) => ({ message, status }), data => ({ status: 200, data }),
      async id => ({ familyID: id }));
  const req = new Request('https://example.invalid', { headers: { 'x-device-install-id': 'install', 'x-device-secret': suppliedSecret } });
  return { response: await handler(req, { installID: 'install', role, inspectOnly }), writes, filters };
}
test('new registration keeps selected role', async () => {
  const r = await register(null, 'parent');
  assert.equal(r.response.data.deviceRole, 'parent');
  assert.equal(r.writes[0].insert.role, 'parent');
});
test('same role has no extra database write', async () => {
  const r = await register(existing, 'child');
  assert.equal(r.response.data.deviceRole, 'child');
  assert.deepEqual(r.writes, []);
});
test('unlinked device can change either role without changing identity', async () => {
  for (const [oldRole, role] of [['child', 'parent'], ['parent', 'child']]) {
    const r = await register({ ...existing, role: oldRole }, role);
    assert.equal(r.response.data.deviceRole, role);
    assert.deepEqual(r.writes, [{ update: { role } }]);
    assert.ok(r.filters.some(([k, v]) => k === 'id' && v === existing.id));
    assert.ok(r.filters.some(([k, v]) => k === 'role' && v === oldRole));
    assert.ok(r.filters.some(([k, v]) => k === 'family_id' && v === null));
  }
});
test('linked device cannot change family role via reinstall', async () => {
  for (const [oldRole, role] of [['child', 'parent'], ['parent', 'child']]) {
    const r = await register({ ...existing, role: oldRole, family_id: 'family' }, role);
    assert.equal(r.response.data.deviceRole, oldRole);
    assert.equal(r.response.data.pairingState.familyID, 'family');
    assert.deepEqual(r.writes, []);
  }
});
test('invalid credentials cannot change role', async () => {
  const r = await register(existing, 'parent', { suppliedSecret: 'b'.repeat(64) });
  assert.equal(r.response.status, 401);
  assert.deepEqual(r.writes, []);
});
test('concurrent pairing and update failure never acknowledge role change', async () => {
  assert.equal((await register(existing, 'parent', { conflict: true })).response.status, 409);
  assert.equal((await register(existing, 'parent', { changeError: { message: 'failure' } })).response.status, 400);
});
test('reinstall inspection never creates devices or changes roles', async () => {
  for (const record of [null, existing, { ...existing, family_id: 'family' }]) {
    const r = await register(record, undefined, { inspectOnly: true });
    assert.equal(r.response.status, 200);
    assert.deepEqual(r.writes, []);
    assert.equal(r.response.data.deviceRole, record?.role ?? null);
    assert.equal(r.response.data.pairingState?.familyID ?? null, record?.family_id ?? null);
  }
});
test('inspection still requires the retained secret', async () => {
  const r = await register(existing, undefined, { inspectOnly: true, suppliedSecret: 'b'.repeat(64) });
  assert.equal(r.response.status, 401);
  assert.deepEqual(r.writes, []);
});

const unlinkBody = source.slice(source.indexOf('async function unlinkDevices('), source.indexOf('async function deleteFamilyData('))
  .replace('deviceId: string, payload: Json = {}): Promise<Response>', 'deviceId, payload = {})');
async function unlink(familyID, expectedFamilyID, failDetach = false) {
  const actions = [];
  const family = '11111111-1111-1111-1111-111111111111';
  const handler = new Function('getDevice', 'asUUIDString', 'errorResponse', 'okResponse', 'notifyChildPinUpdated', 'supabase', 'deleteFamilyData',
    unlinkBody + '; return unlinkDevices;')(
      async () => ({ family_id: familyID }),
      x => typeof x === 'string' && /^[a-f0-9-]{36}$/i.test(x) ? x.toLowerCase() : null,
      (message, status) => ({ message, status }), data => ({ status: 200, data }),
      async id => { actions.push(['notify', id]); },
      { from: table => ({ update: value => ({ eq: async (key, id) => {
        actions.push(['detach', table, value, key, id]);
        return { error: failDetach ? { message: 'error' } : null };
      } }) }) },
      async id => { actions.push(['delete', id]); });
  return { response: await handler('device', { expectedFamilyID }), actions, family };
}
test('reset is fenced to the displayed family and retries are idempotent', async () => {
  const family = '11111111-1111-1111-1111-111111111111';
  const other = '22222222-2222-2222-2222-222222222222';
  const wrong = await unlink(other, family);
  assert.equal(wrong.response.status, 409);
  assert.deepEqual(wrong.actions, []);
  const retry = await unlink(null, family);
  assert.equal(retry.response.status, 200);
  assert.deepEqual(retry.actions, []);
  const invalid = await unlink(family, 'not-a-family');
  assert.equal(invalid.response.status, 400);
  assert.deepEqual(invalid.actions, []);
  const reset = await unlink(family, family);
  assert.equal(reset.response.status, 200);
  assert.deepEqual(reset.actions.map(x => x[0]), ['notify', 'detach', 'delete']);
  assert.equal(reset.actions[2][1], family);
  const failed = await unlink(family, family, true);
  assert.equal(failed.response.status, 400);
  assert.ok(!failed.actions.some(x => x[0] === 'delete'));
});
