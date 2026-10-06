import { execFileSync } from "node:child_process";

export function commitFor(ref) {
  try { return execFileSync("git", ["rev-parse", "--verify", `${ref}^{commit}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
  catch { return null; }
}
export function containsCommit(commit, tip) {
  if (!commit || !tip) return null;
  try { execFileSync("git", ["merge-base", "--is-ancestor", commit, tip], { stdio: "ignore" }); return true; }
  catch (error) { return error.status === 1 ? false : null; }
}
export function releaseRefs(context, sourceSha) {
  const resolve = (release) => release ? { ...release, sha: commitFor(`refs/tags/${release.tag}`) } : null;
  return { code: commitFor(sourceSha), reported: resolve(context.reportedRelease),
    nightly: resolve((context.releases ?? []).find((release) => release.channel === "nightly")),
    regular: resolve((context.releases ?? []).find((release) => release.channel === "regular")) };
}
export function fixEvidence(sha, refs) {
  const commit = /^[a-f0-9]{40}$/i.test(sha ?? "") ? commitFor(sha) : null;
  return { commit, inCode: containsCommit(commit, refs.code), inReportedRelease: containsCommit(commit, refs.reported?.sha),
    inNightlyRelease: containsCommit(commit, refs.nightly?.sha), inRegularRelease: containsCommit(commit, refs.regular?.sha) };
}
export function resolveFix(sha, refs) {
  if (!sha) return { state: "unresolved", commit: null, release: null };
  const evidence = fixEvidence(sha, refs);
  if (!evidence.commit || evidence.inCode !== true) throw new Error("Claimed fix is not a verified commit in the inspected nightly code");
  // An unknown release ancestry must not be presented as proof that no release contains it.
  if (!refs.reported?.sha || (refs.nightly && !refs.nightly.sha) || (refs.regular && !refs.regular.sha)) throw new Error("Release ancestry could not be verified");
  if (evidence.inReportedRelease) return { state: "possible_regression", commit: evidence.commit, release: refs.reported };
  if (evidence.inRegularRelease) return { state: "fixed_regular", commit: evidence.commit, release: refs.regular };
  if (evidence.inNightlyRelease) return { state: "fixed_nightly", commit: evidence.commit, release: refs.nightly };
  return { state: "fixed_unreleased", commit: evidence.commit, release: null };
}
