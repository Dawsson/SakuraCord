# Discord release announcements

Use the shared [evidence, editorial and approval rules](RELEASE_NOTES_STYLE.md).
An announcement highlights what users can do or notice and links them to the
full release record through generated framing. It need not cover every GitHub
section or repeat its wording.

## Authored description

1. A short feature-specific bold headline ending in `🌸` for Regular or `🌙`
   for Nightly.
2. Exactly one blank line, then `**Highlights**`.
3. Four to six concise bullets, with the first immediately below Highlights.

Do not insert an introductory paragraph. The example shows exact line spacing;
expand its placeholders to the appropriate four to six highlights.

```markdown
**Message forwarding, GIFs, and a new media viewer 🌸**

**Highlights**
- [Major feature and what users can do]
- [Another recognizable feature]
- [Visible improvement]
- [Important fix]
```

For a beta, change the headline emoji to `🌙`; use it only there. Name the defining
features rather than saying an update exists or is “ready to test”. Minor polish
can be grouped when listing every change would obscure the main features.
Use natural, varied sentences; imperatives are not required. Aim for approximately
500–800 characters and stay within the validator's hard limit.

## Generated framing

The release action supplies the role mention, tag-derived embed title, track
colour, destination and **View release** button. Only the embed description goes
in `discordAnnouncement`. Do not repeat the version or include role/user mentions,
`@here` or `@everyone`. The action adds those delivery elements at publication.

Before review, check feature specificity, exact line breaks and the distinction
between authored copy and generated framing. Use the [release-copy validator](RELEASING.md)
after saving approved copy; it checks structure, not whether the claims are true.
