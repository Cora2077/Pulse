'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateState, materializeState } = require('../src/payload');
const { registrationBody } = require('./helpers');
const T0 = 1700000000;

test('index point unit and plan revision survive validation and native wire assembly', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.primary.currencyCode = 'KRW';
  body.template.primary.unit = 'points';
  body.template.plans.revision = 'stable-plan-revision';
  body.template.plans.syncState = 'pending';
  body.template.plans.asOf = { encoding: 'unixSeconds', value: T0 - 60 };
  const checked = validateState(body.template);
  assert.equal(checked.ok, true, JSON.stringify(checked));
  const state = checked.value;
  const wire = materializeState(state, { quoteSourceTimeUnix: T0, staleDateUnix: T0 + 300 });
  assert.equal(wire.primary.unit, 'points');
  assert.equal(wire.primary.currencyCode, 'KRW');
  assert.equal(wire.plans.revision, 'stable-plan-revision');
  assert.equal(wire.plans.syncState, 'pending');
  assert.equal(wire.plans.asOf, T0 - 60 - 978307200);
});

test('unknown quote unit fails rather than silently becoming currency', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.primary.unit = 'anything';
  assert.equal(validateState(body.template).ok, false);
});
