import { test, expect } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// The HTML template is embedded and escaped by Ruby; these browser tests exercise
// the exact shipped template with the same JSON escaping, without a Ruby runtime.
test('offline graph explores recorded associations in both directions', async ({ page }, testInfo) => {
  const template = readFileSync('lib/cleave/graph_template.html', 'utf8');
  const dangerous = 'app/</script><script>window.pwned=true</script>.rb';
  const specs = Array.from({ length: 12 }, (_, i) => `spec/${String(i).padStart(2, '0')}_spec.rb`);
  const data = {
    fingerprint: 'a'.repeat(64), inventory_count: 12, specs,
    files: [
      { path: 'app/a/service.rb', hex: '0xfff', root: false, in_inventory: true },
      { path: 'app/b/service.rb', hex: '0x1', root: true, in_inventory: true },
      { path: 'config/missing.yml', hex: '0x0', root: true, in_inventory: false },
      { path: dangerous, hex: '0x2', root: false, in_inventory: false },
    ],
    limitations: ['partial <script> & trace'],
  };
  const json = JSON.stringify(data).replace(/[<>&\u2028\u2029]/g, c => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  const path = testInfo.outputPath('graph.html');
  writeFileSync(path, template.replace('__CLEAVE_GRAPH_DATA__', () => json));
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(pathToFileURL(path).href);
  await expect(page.getByText('Incomplete index.', { exact: false })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'app/a/service.rb' })).toBeVisible();
  await expect(page.getByText('1–8 / 12 recorded associations')).toBeVisible();
  await page.locator('.bottom').getByRole('button', { name: 'Next' }).click();
  await expect(page.getByText('9–12 / 12 recorded associations')).toBeVisible();
  await page.getByRole('button', { name: 'Inspect spec spec/11_spec.rb' }).click();
  await expect(page.getByRole('heading', { name: 'spec/11_spec.rb' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Inspect path app/a/service.rb' })).toBeVisible();
  await page.getByRole('button', { name: 'Observed paths' }).click();
  await page.getByRole('button', { name: 'root scope app/b/service.rb' }).click();
  await expect(page.getByText('Observed in root scope.', { exact: false })).toBeVisible();
  await page.getByLabel('Filter paths').fill('missing');
  await page.getByRole('button', { name: 'root scope config/missing.yml' }).click();
  await expect(page.getByText('Not present in baseline inventory', { exact: false })).toBeVisible();
  await expect(page.getByText('No per-spec associations recorded for this path.')).toBeVisible();
  await page.getByLabel('Filter paths').fill('script');
  await page.locator('.item').click();
  await expect(page.getByRole('heading', { name: dangerous })).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { pwned?: boolean }).pwned)).toBeUndefined();
  expect(errors).toEqual([]);
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test('empty index remains navigable and honest', async ({ page }, testInfo) => {
  const template = readFileSync('lib/cleave/graph_template.html', 'utf8');
  const data = { fingerprint:'b'.repeat(64), inventory_count:0, specs:[], files:[], limitations:['No trace reports supplied.'] };
  const path = testInfo.outputPath('empty.html');
  writeFileSync(path, template.replace('__CLEAVE_GRAPH_DATA__', () => JSON.stringify(data)));
  await page.goto(pathToFileURL(path).href);
  await expect(page.getByRole('heading', { name:'No selection' })).toBeVisible();
  await expect(page.getByText('0 matching observed paths')).toBeVisible();
  await page.getByRole('button', { name:'Indexed specs' }).click();
  await expect(page.getByText('0 matching indexed specs')).toBeVisible();
});

test('large bitmaps and long lists remain fully inspectable', async ({ page }, testInfo) => {
  const template = readFileSync('lib/cleave/graph_template.html', 'utf8');
  const specs = Array.from({ length: 1200 }, (_, i) => `spec/${String(i).padStart(4, '0')}_spec.rb`);
  const data = {
    fingerprint: 'c'.repeat(64), inventory_count: 1200, specs,
    files: [{ path: 'app/service.rb', hex: `0x${((1n << 1199n) | 1n).toString(16)}`, root: false, in_inventory: true }],
    limitations: ['partial'],
  };
  const path = testInfo.outputPath('large.html');
  writeFileSync(path, template.replace('__CLEAVE_GRAPH_DATA__', () => JSON.stringify(data)));
  await page.goto(pathToFileURL(path).href);
  await expect(page.getByRole('button', { name: 'Inspect spec spec/1199_spec.rb' })).toBeVisible();
  await page.getByRole('button', { name: 'Inspect spec spec/1199_spec.rb' }).click();
  await expect(page.getByText('1151–1200 / 1200')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'spec/1199_spec.rb' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Inspect path app/service.rb' })).toBeVisible();
  await page.getByLabel('Filter paths').fill('0000');
  await expect(page.getByText('1 matching indexed specs')).toBeVisible();
});
