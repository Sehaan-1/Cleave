import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

const files = "tests/fixtures/artifacts/";
async function enableLocalMode(page: import('@playwright/test').Page, missing = false) {
  await page.route('**/artifacts/*.json', async route => {
    const name = new URL(route.request().url()).pathname.split('/').pop()!;
    if (missing && name === 'bitmap_index.json') return route.fulfill({ status: 404, body: 'Not found' });
    return route.fulfill({ status: 200, contentType:'application/json', body:readFileSync(files + name, 'utf8') });
  });
  await page.route(/\/$/, async route => {
    const response = await route.fetch();
    const html = (await response.text()).replace('</head>', '<meta name="cleave-local-ui" content="1"></head>');
    await route.fulfill({ response, body: html });
  });
}

test('local UI loads project snapshot without mixing simulator data', async ({ page }) => {
  await enableLocalMode(page);
  await page.goto('/');
  await expect(page.getByRole('heading', { name:'app/服务.rb' })).toBeVisible();
  await expect(page.getByText('Project snapshot · loopback')).toBeVisible();
  await expect(page.getByText(/CLI’s startup snapshot/)).toBeVisible();
  await expect(page.getByText('2 indexed specs')).toBeVisible();
  await page.getByRole('button', { name:'Simulator' }).click();
  await expect(page.getByText('Browser simulator')).toBeVisible();
  await page.getByRole('button', { name:'Import artifacts' }).click();
  await expect(page.getByRole('heading', { name:'app/服务.rb' })).toBeVisible();
});

test('local UI shows fetch errors without substituting fixture data', async ({ page }) => {
  await enableLocalMode(page, true);
  await page.goto('/');
  await expect(page.getByRole('alert')).toContainText('HTTP 404');
  await expect(page.getByText('No artifacts loaded')).toBeVisible();
  await expect(page.getByText('2 indexed specs')).toHaveCount(0);
});
