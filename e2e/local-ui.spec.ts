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

test('packaged loopback server renders real artifacts under its content policy', async ({ page }) => {
  test.skip(process.env.CLEAVE_REAL_UI !== '1', 'Requires Ruby and Bundler');
  const { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, resolve } = await import('node:path');
  const { spawn, spawnSync } = await import('node:child_process');
  const project = mkdtempSync(join(tmpdir(), 'cleave-browser-'));
  let child: ReturnType<typeof spawn> | undefined;
  try {
    mkdirSync(join(project, '.cleave'));
    for (const name of ['inventory.json', 'bitmap_index.json']) copyFileSync(resolve(files, name), join(project, '.cleave', name));
    writeFileSync(join(project, 'Gemfile'), `source 'https://rubygems.org'\ngem 'cleave-ste', path: ${JSON.stringify(resolve('.'))}\n`);
    const lock = spawnSync('bundle', ['lock', '--local'], { cwd:project, encoding:'utf8' });
    if (lock.status !== 0) throw new Error(`bundle lock failed: ${lock.stdout} ${lock.stderr}`);
    child = spawn('bundle', ['exec', 'cleave', 'ui', '--no-open'], { cwd:project, stdio:['ignore','pipe','pipe'] });
    const proc = child;
    const url = await new Promise<string>((resolveUrl, reject) => {
      let output = '';
      const timer = setTimeout(() => reject(new Error(`Server startup timed out: ${output}`)), 20_000);
      proc.stdout!.on('data', chunk => { output += String(chunk); const found = output.match(/http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{64}\//); if (found) { clearTimeout(timer); resolveUrl(found[0]); } });
      proc.stderr!.on('data', chunk => { output += String(chunk); });
      proc.on('exit', code => { clearTimeout(timer); reject(new Error(`Server exited ${code}: ${output}`)); });
      proc.on('error', reject);
    });
    const errors: string[] = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(url);
    await expect(page.getByRole('heading', { name:'app/服务.rb' })).toBeVisible();
    await expect(page.getByText('Project snapshot · loopback')).toBeVisible();
    await expect(page.locator('.artifact-spec').filter({ hasText:'spec/beta_spec.rb' })).toBeVisible();
    expect(errors).toEqual([]);
  } finally {
    if (child && child.exitCode === null) {
      const proc = child;
      const exited = new Promise<void>(resolveExit => proc.once('exit', () => resolveExit()));
      proc.kill('SIGINT');
      await Promise.race([exited, new Promise<void>(resolveWait => setTimeout(resolveWait, 3000))]);
      if (proc.exitCode === null) proc.kill('SIGKILL');
    }
    rmSync(project, { recursive:true, force:true });
  }
});
