import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { resolveFix } from "./release-evidence.mjs";

test("distinguishes published fixes, unreleased code, and regressions using Git history", () => {
  const directory = mkdtempSync(join(tmpdir(), "sakuracord-release-evidence-"));
  const previous = process.cwd();
  const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  try {
    process.chdir(directory);
    git("init", "-q");
    git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.invalid");
    const commit = (text) => {
      writeFileSync("source.txt", text); git("add", "source.txt");
      git("-c", "commit.gpgsign=false", "commit", "-qm", text); return git("rev-parse", "HEAD");
    };
    const regular = commit("old behavior");
    const publishedFix = commit("first fix");
    const unreleasedFix = commit("second fix");
    const refs = { code: unreleasedFix, reported: { sha: regular }, regular: { sha: regular }, nightly: { sha: publishedFix } };
    assert.equal(resolveFix(publishedFix, refs).state, "fixed_nightly");
    assert.equal(resolveFix(unreleasedFix, refs).state, "fixed_unreleased");
    assert.equal(resolveFix(publishedFix, { ...refs, regular: { sha: publishedFix } }).state, "fixed_regular");
    assert.equal(resolveFix(publishedFix, { ...refs, reported: { sha: publishedFix } }).state, "possible_regression");
    assert.equal(resolveFix(null, refs).state, "unresolved");
    assert.throws(() => resolveFix("f".repeat(40), refs), /not a verified commit/);
    assert.throws(() => resolveFix(publishedFix, { ...refs, nightly: { sha: null } }), /could not be verified/);
  } finally {
    process.chdir(previous); rmSync(directory, { recursive: true, force: true });
  }
});
