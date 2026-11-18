import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

const fixture = "tests/fixtures/artifacts/";

test("imports a real v1 pair locally and keeps simulator data separate", async ({ page }) => {
  const requests: string[] = [];
  page.on('request', req => requests.push(req.url()));
  await page.goto("/");
  await page.getByRole("button", { name: "Import artifacts" }).click();
  await expect(page.getByRole("heading", { name: "Inspect real observations" })).toBeVisible();
  await page.getByLabel("Inventory JSON").setInputFiles(fixture + "inventory.json");
  await page.getByLabel("Bitmap index JSON").setInputFiles(fixture + "bitmap_index.json");
  const requestCount = requests.length;
  await page.getByRole("button", { name: "Load artifacts" }).click();
  await expect(page.getByRole("heading", { name: "app/服务.rb" })).toBeVisible();
  await expect(page.getByText("2 indexed specs")).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/alpha_spec.rb" })).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" })).toBeVisible();
  await expect(page.getByText("Unavailable", { exact: true }).first()).toBeVisible();
  await page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" }).click();
  await expect(page.getByRole("heading", { name: "spec/beta_spec.rb" })).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "config/missing.json" })).toBeVisible();
  await page.locator(".artifact-spec").filter({ hasText: "config/missing.json" }).click();
  await expect(page.getByText("Absent from baseline inventory", { exact: false })).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" })).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/alpha_spec.rb" })).toHaveCount(0);
  await page.getByRole("button", { name: /config\/boot.yml/ }).click();
  await expect(page.getByText("Root scope has no individual spec attribution.", { exact: false })).toBeVisible();
  await expect(page.getByText("No per-spec associations recorded.")).toBeVisible();
  await page.getByLabel("Search artifact paths").fill("alpha");
  await expect(page.getByText("1 matching paths")).toBeVisible();
  expect(requests.slice(requestCount)).toEqual([]);
  await page.getByRole("button", { name: "Simulator" }).click();
  await expect(page.getByText("Browser simulator")).toBeVisible();
  await expect(page.getByTestId("selected-count")).toHaveText("41");
});

test("invalid and mismatched artifacts fail without showing stale results", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Import artifacts" }).click();
  await page.getByLabel("Inventory JSON").setInputFiles(fixture + "inventory.json");
  await page.getByLabel("Bitmap index JSON").setInputFiles(fixture + "bitmap_index.json");
  await page.getByRole("button", { name: "Load artifacts" }).click();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" })).toBeVisible();
  const wrong = JSON.parse(readFileSync(fixture + "bitmap_index.json", "utf8"));
  wrong.inventory_fingerprint = "0".repeat(64);
  await page.getByLabel("Bitmap index JSON").setInputFiles({ name:"wrong.json", mimeType:"application/json", buffer:Buffer.from(JSON.stringify(wrong)) });
  await expect(page.getByText("No artifacts loaded")).toBeVisible();
  await page.getByRole("button", { name: "Load artifacts" }).click();
  await expect(page.getByRole("alert")).toContainText("does not match this inventory");
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" })).toHaveCount(0);
});

test("compact inspector allows navigation without page overflow", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await page.getByRole("button", { name: "Import artifacts" }).click();
  await page.getByLabel("Inventory JSON").setInputFiles(fixture + "inventory.json");
  await page.getByLabel("Bitmap index JSON").setInputFiles(fixture + "bitmap_index.json");
  await page.getByRole("button", { name: "Load artifacts" }).click();
  await page.getByRole("button", { name: /config\/missing.json/ }).click();
  await expect(page.getByRole("heading", { name: "config/missing.json" })).toBeVisible();
  await expect(page.locator(".artifact-spec").filter({ hasText: "spec/beta_spec.rb" })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});
