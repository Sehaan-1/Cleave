import { test, expect } from "@playwright/test";

test("presets, guardrail attribution, root fallback and custom edits stay in sync", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  const count = page.getByTestId("selected-count");
  await expect(count).toHaveText("41");
  await expect(
    page.getByRole("table", { name: "Spec decisions" }),
  ).toHaveAttribute("aria-rowcount", "1201");
  expect(await page.locator("[data-spec-id]").count()).toBeLessThan(40);
  await page.getByRole("button", { name: /^Scenario B:/ }).click();
  await expect(count).toHaveText("25");
  await expect(
    page.getByText("0 static AST changes. Scoped File.open caught 25 specs."),
  ).toBeVisible();
  await page.getByRole("button", { name: "Prism AST", exact: true }).click();
  await expect(page.getByText("No matching edges")).toBeVisible();
  await page.getByRole("button", { name: /^Scenario C:/ }).click();
  await expect(count).toHaveText("10");
  await page
    .getByRole("button", { name: "Guardrails", exact: true })
    .first()
    .click();
  await expect(
    page.getByRole("button", { name: /migration_schema_spec\.rb/ }).first(),
  ).toBeVisible();
  await page
    .getByRole("button", { name: /migration_schema_spec\.rb/ })
    .first()
    .click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByText(
      /watched pattern matches db\/migrations\/20261118_add_settlement_index.rb/,
    ),
  ).toBeVisible();
  await expect(dialog.getByText("Prism AST landmarks")).toBeVisible();
  await page.getByRole("button", { name: "Close inspector" }).click();
  await page.getByRole("button", { name: /^Scenario D:/ }).click();
  await expect(count).toHaveText("1,200");
  await page
    .getByRole("button", { name: "Preview root-scope refactor" })
    .click();
  await expect(count).toHaveText("23");
  await page.getByLabel("Search file paths").fill("spec_helper.rb");
  await page
    .getByRole("checkbox", { name: "Modify spec/spec_helper.rb" })
    .check();
  await expect(count).toHaveText("1,200");
  await page.getByRole("button", { name: /Shadow audit/ }).click();
  await expect(dialog.getByText("No recorded replay")).toBeVisible();
  await page.getByRole("button", { name: "Close inspector" }).click();
  expect(errors).toEqual([]);
});

test("word bits and virtualized spec table inspect the same decision", async ({
  page,
}) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Bitmap words" }).click();
  await expect(page.getByText("FINAL_EXECUTION_MASK")).toBeVisible();
  await page.getByRole("button", { name: "Inspect bit 0: selected" }).click();
  await expect(
    page
      .getByRole("dialog")
      .getByText("idempotency_coordinator_spec.rb")
      .first(),
  ).toBeVisible();
  await page.getByRole("button", { name: "Close inspector" }).click();
  await page.getByRole("button", { name: "Spec table" }).click();
  const scroll = page.getByLabel("Scrollable spec decisions");
  await scroll.evaluate((el) => {
    el.scrollTop = el.scrollHeight;
  });
  await expect(page.locator('[data-spec-id="1199"]')).toBeVisible();
  expect(await page.locator("[data-spec-id]").count()).toBeLessThan(40);
  await page.getByLabel("Search specs").fill("migration_schema_spec.rb");
  await expect(
    page.getByRole("table", { name: "Spec decisions" }),
  ).toHaveAttribute("aria-rowcount", "2");
});

test("compact layout fits and switches panels and scenarios", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    390,
  );
  await page
    .getByRole("combobox", { name: "Commit scenario" })
    .selectOption("B");
  await expect(page.getByTestId("selected-count")).toHaveText("25");
  await page
    .getByRole("navigation", { name: "Workbench panels" })
    .getByRole("button", { name: "Inventory" })
    .click();
  await expect(
    page.getByRole("heading", { name: "File inventory" }),
  ).toBeVisible();
  await page
    .getByRole("navigation", { name: "Workbench panels" })
    .getByRole("button", { name: "Matrix" })
    .click();
  await expect(
    page.getByRole("heading", { name: "Execution matrix" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Bitmap words" }).click();
  await expect(page.getByText("FINAL_EXECUTION_MASK")).toBeVisible();
});
