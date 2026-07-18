# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

- Use GitHub's [private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  ("Report a vulnerability" under the repository's Security tab), or
- Email gjermund@garaba.net.

Please include steps to reproduce and the affected version. You can expect an
initial acknowledgement within a few days.

## Scope and context

Summond installs a background LaunchAgent that requires Accessibility and Input
Monitoring permission and installs a global `CGEvent` keyboard tap. It also
calls private SkyLight window-server functions, resolved at runtime, for
current-Space membership queries and for moving windows between Spaces. Reports
about the XPC boundary between the app and the agent, the code-signing
requirements enforced on that boundary, permission handling, or the event tap
are especially in scope.
