#!/usr/bin/env node
// List the GitHub issues a release will ship, as Markdown, to draft
// Releases/<tag>.json. Issues marked "status: in nightly" ship with the next
// tag cut from nightly; --milestone also includes that milestone's shipped
// issues (useful for a regular release that collects several betas).
//
//   node script/release_issues.mjs [--milestone 0.1.7]

import { execFileSync } from "node:child_process";

const args = process.argv.slice(2);
const milestone = args.includes("--milestone") ? args[args.indexOf("--milestone") + 1] : null;
const list = (extra) =>
  JSON.parse(
    execFileSync(
      "gh",
      ["issue", "list", "--limit", "500", "--json", "number,title,issueType,labels,url", ...extra],
      { encoding: "utf8" },
    ),
  );

const issues = new Map();
for (const issue of list(["--state", "open", "--label", "status: in nightly"])) issues.set(issue.number, issue);
if (milestone) {
  for (const issue of list(["--state", "closed", "--milestone", milestone, "--label", "status: shipped"])) {
    issues.set(issue.number, issue);
  }
}

const kind = (issue) => (issue.issueType?.name ?? "").toLowerCase();
const section = (title, entries) =>
  entries.length ? `## ${title}\n\n${entries.map((issue) => `- ${issue.title} (#${issue.number})`).join("\n")}\n` : "";
const all = [...issues.values()].sort((a, b) => a.number - b.number);
const output = [
  section("Features", all.filter((issue) => kind(issue) === "feature")),
  section("Fixes", all.filter((issue) => kind(issue) !== "feature")),
]
  .filter(Boolean)
  .join("\n");
process.stdout.write(output || "No issues are waiting to ship.\n");
