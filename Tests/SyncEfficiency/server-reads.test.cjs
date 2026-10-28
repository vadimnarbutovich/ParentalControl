const assert = require('node:assert/strict');
const test = require('node:test');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const read = file => readFileSync(resolve(__dirname, '../..', file), 'utf8');
const source = read('supabase/functions/parental-control-sync/index.ts');
const functions = {
  fetchDesiredFocusState: 'device', fetchCommandStatus: 'requester',
  fetchChildLocation: 'parent', listBlockSchedules: 'device', listChildTasks: 'device',
};
function section(name) {
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf('\n}\n', start) + 3;
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
}
function handler(name, data = null, error = null) {
  const calls = [];
  const db = { from(table) {
    calls.push(['from', table]);
    assert.notEqual(table, 'devices', 'Reuse only this authenticated request, never read/cache identity again');
    const query = { then(done, fail) { return Promise.resolve({ data, error }).then(done, fail); } };
    for (const method of ['select', 'eq', 'is', 'order', 'maybeSingle']) {
      query[method] = (...args) => { calls.push([method, ...args]); return query; };
    }
    return query;
  } };
  const body = section(name).replaceAll(': DeviceContext', '').replaceAll(': Json', '')
    .replaceAll(': Promise<Response>', '').replaceAll(' as BlockScheduleRow', '').replaceAll(' as ChildTaskRow', '');
  const run = new Function('supabase', 'asString', 'okResponse', 'errorResponse', 'mapBlockScheduleForClient', 'mapChildTaskForClient',
    body + `; return ${name};`)(db, x => typeof x === 'string' ? x : null,
      data => ({ status: 200, data }), (message, status) => ({ status, message }), x => x, x => x);
  return { run, calls };
}
const parent = { id: 'p', family_id: 'f', role: 'parent' };
const child = { id: 'c', family_id: 'f', role: 'child' };
for (const name of Object.keys(functions)) {
  test(`${name}: one data read, same family filter, errors preserved`, async () => {
    assert.match(source, new RegExp(`return await ${name}\\(authed.device(?:, payload)?\\)`));
    const data = name === 'fetchCommandStatus' ? { id: 'command', family_id: 'f', requested_by_device_id: 'p', status: 'applied' } : null;
    const h = handler(name, data);
    assert.equal((await h.run(parent, { commandID: 'command' })).status, 200);
    assert.equal(h.calls.filter(x => x[0] === 'from').length, 1);
    if (name !== 'fetchCommandStatus') assert.ok(h.calls.some(x => x[0] === 'eq' && x[1] === 'family_id' && x[2] === 'f'));
    assert.equal((await handler(name, null, { message: 'read failed' }).run(parent, { commandID: 'command' })).status, 400);
    const unlinked = handler(name);
    assert.equal((await unlinked.run({ ...parent, family_id: null }, { commandID: 'command' })).status, 403);
    assert.equal(unlinked.calls.length, 0);
  });
}
test('command status cannot leak another family or another parent command', async () => {
  assert.equal((await handler('fetchCommandStatus', { family_id: 'other', requested_by_device_id: 'p' })
    .run(parent, { commandID: 'x' })).status, 403);
  assert.equal((await handler('fetchCommandStatus', { family_id: 'f', requested_by_device_id: 'other' })
    .run(parent, { commandID: 'x' })).status, 403);
  assert.equal((await handler('fetchCommandStatus', { family_id: 'f', requested_by_device_id: 'p' })
    .run(child, { commandID: 'x' })).status, 200);
  const missing = handler('fetchCommandStatus');
  assert.equal((await missing.run(parent, {})).status, 400);
  assert.equal(missing.calls.length, 0);
});
test('location remains parent-only; expired approved tasks still filtered', async () => {
  const h = handler('fetchChildLocation');
  assert.equal((await h.run(child)).status, 403);
  assert.equal(h.calls.length, 0);
  const tasks = [{ id: 1, status: 'pending' }, { id: 2, status: 'approved', approved_at: '2000-01-01' },
    { id: 3, status: 'approved', approved_at: new Date().toISOString() }];
  assert.deepEqual((await handler('listChildTasks', tasks).run(child)).data.tasks.map(x => x.id), [1, 3]);
});
test('poll output SQL is unchanged except atomic expiration; legacy cleanup retained', () => {
  const old = read('supabase/migrations/202610120001_poll_snapshot.sql').split('create function')[1];
  const updated = read('supabase/migrations/202610270001_poll_expiration_in_snapshot.sql').split('create or replace function')[1];
  const normalized = updated.replace('plpgsql volatile', 'plpgsql stable')
    .replace(/  -- Same TTL,[\s\S]*?and expires_at<=at_time;\n/, '');
  assert.equal(normalized, old);
  assert.doesNotMatch(section('childPoll'), /expireStalePendingCommands/);
  assert.doesNotMatch(section('parentPoll'), /expireStalePendingCommands/);
  for (const name of ['fetchPendingCommands', 'fetchLinkHealth', 'retryStuckCommandsBatch']) {
    assert.match(section(name), /expireStalePendingCommands/, `${name} must keep legacy cleanup`);
  }
});
test('authentication, mutation rechecks and all maintenance notifications remain intact', () => {
  assert.match(source, /const authed = await requireDevice\(req\)/);
  assert.match(section('requireDevice'), /data.device_secret !== secret/);
  for (const name of ['unlinkDevices', 'joinPairingCode', 'generatePairingCode', 'upsertChildRuntimeBundle']) {
    assert.match(section(name), /await getDevice\(deviceId\)/);
  }
  const maintenance = section('maintainAccessLeases');
  assert.ok(maintenance.indexOf('await refreshOwner') < maintenance.indexOf('await notifyChildTasksUpdated'));
  assert.ok(maintenance.indexOf('await notifyChildTasksUpdated') < maintenance.indexOf('pc_access_finish_maintenance'));
  assert.doesNotMatch(maintenance.split('try {')[1], /if \(/, 'Do not suppress renewal, expiry or uncertain-paid delivery');
});
