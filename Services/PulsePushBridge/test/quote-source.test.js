'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createQuoteSource } = require('../src/quote-source');
const { createHttpClient } = require('../src/sources/http');
const { unixFromNewYorkParts } = require('../src/sources/time');

function naverRow(overrides = {}) { return { itemCode: '005930', stockName: '삼성전자', closePriceRaw: 208000,
  compareToPreviousClosePriceRaw: -24000, localTradedAt: '2026-10-16T10:45:00+09:00', marketStatus: 'OPEN', ...overrides }; }
const sourceWith = (body) => createQuoteSource('public', { fetchImpl: async () => new Response(JSON.stringify(body)) });

test('the client default cannot independently refresh and selecting public opens no socket', () => {
  let calls = 0;
  assert.equal(createQuoteSource('client').isRefreshable('005930.KS'), false);
  const source = createQuoteSource('public', { fetchImpl: () => { calls++; throw Error('must not fetch'); } });
  assert.equal(source.isRefreshable('005930.KS'), true);
  assert.equal(calls, 0);
});
test('Naver preserves leading-zero identity and source clock rather than stamping receipt time', async () => {
  const source = sourceWith({ datas: [naverRow()] });
  const quote = await source.refresh('005930.KS');
  assert.equal(quote.price, 208000);
  assert.equal(quote.change, -24000);
  assert.equal(quote.symbolKey, '005930.KS');
  assert.equal(quote.quoteSourceTimeUnix, Date.parse('2026-10-16T10:45:00+09:00') / 1000);
});
test('US source wall clocks honor both EST and EDT', () => {
  assert.equal(unixFromNewYorkParts(2026, 7, 20, 16, 0, 1), Date.parse('2026-07-20T20:00:01Z') / 1000);
  assert.equal(unixFromNewYorkParts(2026, 1, 20, 16, 0, 1), Date.parse('2026-01-20T21:00:01Z') / 1000);
});
test('missing source clock and zero price are rejected, never replaced with now or a fake quote', async () => {
  for (const row of [naverRow({ localTradedAt: '' }), naverRow({ closePriceRaw: 0 })]) {
    await assert.rejects(sourceWith({ datas: [row] }).refresh('005930.KS'), e => e.reason === 'source-invalid');
  }
});
test('unsupported markets and path injection cannot contact any quote host', async () => {
  let calls = 0;
  const source = createQuoteSource('public', { fetchImpl: () => { calls++; throw Error('must not fetch'); } });
  for (const symbol of ['BTC/USDT', '7203.T', 'SPX', '005930.KS/evil', 'https://localhost/', '../881155.SH']) {
    await assert.rejects(source.refresh(symbol), e => e.reason === 'unsupported-market');
  }
  assert.equal(calls, 0);
});
test('pinned source refuses redirects and oversized streaming bodies', async () => {
  const redirected = createHttpClient({ host: 'qt.gtimg.cn', fetchImpl: async () => new Response('', { status: 302 }) });
  await assert.rejects(redirected.request('/q=usAAPL'), e => e.reason === 'source-unavailable');
  const huge = createHttpClient({ host: 'qt.gtimg.cn', maxBytes: 4, fetchImpl: async () => new Response('123456') });
  await assert.rejects(huge.request('/q=usAAPL'), e => e.reason === 'source-invalid');
});
