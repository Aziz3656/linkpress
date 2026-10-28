'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { analyze, outputDimensions } = require('../src/core/resolution');

const src1080 = { width: 1920, height: 1080, duration: 600, size: 600 * 8e6 / 8, hasAudio: true };

test('downscale reports a smaller estimated size', () => {
  const r = analyze(src1080, '480p');
  assert.equal(r.mode, 'downscale');
  assert.ok(r.estimatedBytes < src1080.size);
  assert.ok(r.deltaPct < 0);
});

test('upscale is flagged and grows the file', () => {
  const r = analyze({ width: 854, height: 480, duration: 60, size: 60 * 1.2e6 / 8 }, '1080p');
  assert.equal(r.mode, 'upscale');
  assert.ok(r.deltaBytes > 0);
});

test('same resolution and unknown metadata', () => {
  assert.equal(analyze(src1080, '1080p').mode, 'same');
  assert.equal(analyze({}, '720p').mode, 'unknown');
});

test('portrait video uses the short side', () => {
  const portrait = { width: 1080, height: 1920, duration: 10, size: 1e7 };
  assert.equal(analyze(portrait, '720p').mode, 'downscale');
  assert.deepEqual(outputDimensions(portrait, '720p'), { width: 720, height: 1280 });
});

test('output dimensions are even', () => {
  const d = outputDimensions({ width: 1000, height: 562 }, '240p');
  assert.equal(d.height, 240);
  assert.equal(d.width % 2, 0);
});
