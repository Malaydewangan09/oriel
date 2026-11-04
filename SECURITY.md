# Security

Sill stores what you copy, so a bug that leaks it matters more than most.

Report security problems privately through [GitHub's private vulnerability reporting](https://github.com/Malaydewangan09/sill/security/advisories/new), not in a public issue. Include steps to reproduce and the version or commit you tested.

In scope: secrets that get indexed or kept past their two-minute lifetime, data leaving the Mac other than through Hand to Claude, SQL injection through copied text, and anything that lets another process read Sill's database without the user's file permissions.
