import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";

const plan = readFileSync('tests/fixtures/plans/plan.json', 'utf8');
async function mockPlan(page: Page, body = plan) {
  await page.route('**/artifacts/plan.json', route => route.fulfill({ status: 200, contentType: 'application/json', body }));
  await page.route('**/artifacts/inventory.json', route => route.fulfill({ status: 200, contentType: 'application/json', body: readFileSync('tests/fixtures/artifacts/inventory.json', 'utf8') }));
  await page.route('**/artifacts/bitmap_index.json', route => route.fulfill({ status: 200, contentType: 'application/json', body: readFileSync('tests/fixtures/artifacts/bitmap_index.json', 'utf8') }));
  await page.route(/\/$/, async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: (await response.text()).replace('</head>', '<meta name="cleave-local-ui" content="1"><meta name="cleave-local-plan" content="1"></head>') });
  });
}

test('project plan shows attribution and remains separate from artifacts and simulator', async ({ page }) => {
  await mockPlan(page); await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Diagnostic selection' })).toBeVisible();
  await expect(page.getByText('Candidate specs are not an execution list.')).toBeVisible();
  await expect(page.getByText('Observed dependency')).toBeVisible();
  await page.getByRole('button', { name: /app\/服务.rb/ }).click();
  await expect(page.getByText('2 shown')).toBeVisible();
  await page.getByRole('button', { name: /spec\/beta_spec.rb/ }).click();
  await expect(page.getByText(/CallNode · line 3/)).toBeVisible();
  await page.getByRole('button', { name: 'Clear' }).click();
  await page.getByRole('button', { name: /spec\/gamma_spec.rb/ }).click();
  await expect(page.getByText('Full-suite fallback', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Artifacts', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'app/服务.rb' })).toBeVisible();
  await page.getByRole('button', { name: 'Project plan' }).click();
  await expect(page.getByRole('heading', { name: 'Diagnostic selection' })).toBeVisible();
  await page.getByRole('button', { name: 'Simulator' }).click();
  await expect(page.getByText('Browser simulator')).toBeVisible();
});

test('rejects invalid plan rather than showing fabricated results', async ({ page }) => {
  const invalid = JSON.parse(plan); invalid.execution_ready = true;
  await mockPlan(page, JSON.stringify(invalid)); await page.goto('/');
  await expect(page.getByRole('alert')).toContainText('safety flags');
  await expect(page.getByRole('heading', { name: 'Diagnostic selection' })).toHaveCount(0);
});

test('compact plan navigation keeps panels usable without page scroll', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockPlan(page); await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Diagnostic selection' })).toBeVisible();
  await page.getByRole('button', { name: 'Changes', exact: true }).click();
  await page.getByRole('button', { name: /app\/服务.rb/ }).click();
  await page.getByRole('button', { name: /spec\/beta_spec.rb/ }).click();
  await expect(page.getByText(/CallNode · line 3/)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight)).toBe(true);
});

test('real loopback UI renders a freshly generated Ruby plan', async ({ page }) => {
  test.skip(process.env.CLEAVE_REAL_UI !== '1', 'Requires Ruby and Bundler');
  test.setTimeout(120_000);
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, resolve } = await import('node:path');
  const { spawn, spawnSync } = await import('node:child_process');
  const project = mkdtempSync(join(tmpdir(), 'cleave-real-plan-'));
  let child: ReturnType<typeof spawn> | undefined;
  const root = resolve('.');
  const env = { ...process.env, BUNDLE_GEMFILE: join(project, 'Gemfile'), BUNDLE_FROZEN: 'false', ...(existsSync(join(root, 'vendor/bundle')) ? { BUNDLE_PATH: join(root, 'vendor/bundle') } : {}) };
  function run(command: string, args: string[]) {
    const result = spawnSync(command, args, { cwd: project, env, encoding: 'utf8', timeout: 50_000 });
    if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  }
  try {
    mkdirSync(join(project, 'spec'));
    writeFileSync(join(project, 'Gemfile'), `source 'https://rubygems.org'\ngem 'cleave-ste', path: ${JSON.stringify(root)}\ngem 'rspec', '~> 3.13'\n`);
    writeFileSync(join(project, '.gitignore'), '.cleave/\n');
    writeFileSync(join(project, 'data.json'), '{}');
    writeFileSync(join(project, 'spec/real_spec.rb'), "RSpec.describe('real') { it('reads') { File.read('data.json') } }\n");
    run('git', ['init', '-q']);
    run('bundle', ['lock', '--local']);
    run('bundle', ['exec', 'cleave', 'run', '--trace', '--index']);
    writeFileSync(join(project, 'data.json'), '{"changed":true}');
    child = spawn('bundle', ['exec', 'cleave', 'ui', '--plan', '--no-open'], { cwd: project, stdio: ['ignore', 'pipe', 'pipe'], env });
    const proc = child;
    const url = await new Promise<string>((resolveUrl, reject) => {
      let output = '';
      const timer = setTimeout(() => reject(new Error(`Server startup timed out: ${output}`)), 50_000);
      proc.stdout!.on('data', chunk => { output += String(chunk); const found = output.match(/http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{64}\//); if (found) { clearTimeout(timer); resolveUrl(found[0]); } });
      proc.stderr!.on('data', chunk => { output += String(chunk); });
      proc.on('exit', code => { clearTimeout(timer); reject(new Error(`Server exited ${code}: ${output}`)); });
      proc.on('error', reject);
    });
    const errors: string[] = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(url);
    await expect(page.getByRole('heading', { name: 'Diagnostic selection' })).toBeVisible();
    await expect(page.getByRole('button', { name: /data.json/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /spec\/real_spec.rb/ })).toBeVisible();
    await expect(page.getByText('Observed dependency')).toBeVisible();
    await expect(page.getByText('Candidate specs are not an execution list.')).toBeVisible();
    expect(errors).toEqual([]);
  } finally {
    if (child && child.exitCode === null) {
      const proc = child;
      const exited = new Promise<void>(resolveExit => proc.once('exit', () => resolveExit()));
      proc.kill('SIGINT');
      await Promise.race([exited, new Promise<void>(resolveWait => setTimeout(resolveWait, 3000))]);
      if (proc.exitCode === null) proc.kill('SIGKILL');
    }
    rmSync(project, { recursive: true, force: true });
  }
});
