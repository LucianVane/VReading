# Security Policy

## Supported versions

Only the latest release on the `main` branch receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue. Instead, use GitHub's
[private vulnerability reporting](../../security/advisories/new).

Include steps to reproduce, affected version, and impact. We aim to acknowledge reports within 7 days.

## Scope notes

- The Wi-Fi transfer feature runs an HTTP server on the local network while it is open. Issues that let a LAN peer access data beyond the transfer page are in scope.
- API keys entered by users are stored on-device. Leaking them off-device is in scope.
- Keys you bake into your own build via `Local.xcconfig` can be extracted from the binary — this is expected and out of scope.
