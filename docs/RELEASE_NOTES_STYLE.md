# GitHub release notes

GitHub notes are the detailed release record and Sparkle update text. The shorter
[Discord announcement](DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md) follows the same
evidence and editorial rules below with its own format. Publishing mechanics
belong in [Releasing](RELEASING.md).

## Evidence and scope

Resolve the maintainer's exact stable or beta tag and its comparison base. Inspect
an existing GitHub Release before deciding whether this is new copy or a repair.
Review commits, tagged code, tests and documentation; commit subjects alone are
not sufficient evidence. Include only behaviour in that tagged tree, not later
unreleased changes. Display beta tags as `vX.Y.Z Beta N` in authored prose.

## Shared editorial rules

- Name features and resulting behaviour in familiar product language. Combine
  related changes, but keep distinct major features recognizable.
- State only what the evidence supports. Qualify incomplete features; avoid
  unsupported superlatives, compatibility claims and generic promotional filler.
- Broad wording such as “quality-of-life improvements” is appropriate only for
  diffuse minor polish, supported by representative concrete examples.
- Include technical details when they explain a shipped outcome. Omit internal
  class names, test counts and CI bookkeeping that do not help the reader.
- Review specificity, scope and readability before presenting the draft.

## GitHub layout

Start with one paragraph naming the version and its main changes. Follow with
three to six sentence-case sections grouped by recognizable product area, then
complete-sentence bullets. Lead bullets with direct past-tense verbs such as
“Added”, “Fixed” or “Improved”. Put features/fixes before relevant maintenance.
Use no emoji. End with the exact comparison link.

```markdown
SakuraCord vX.Y.Z adds [major features]. It also improves [important areas].

## Messaging and attachments

- Added [specific behaviour].
- Fixed [specific problem and resulting behaviour].

## Profiles and settings

- Added [specific capability].

## Performance and reliability

- Improved [verified outcome].

**Full Changelog:** [vPREVIOUS...vX.Y.Z](https://github.com/SakuraCordApp/SakuraCord/compare/vPREVIOUS...vX.Y.Z)
```

## Review and storage

Present GitHub and Discord drafts separately in the same review. Obtain maintainer
approval before writing `Releases/<tag>.json`, unless the maintainer explicitly
asked to save immediately. Store the exact reviewed GitHub Markdown in
`githubDescription` and the authored Discord description in `discordAnnouncement`.
Do not silently convert one into the other. Validate the file using the command
in the release runbook before tagging.
