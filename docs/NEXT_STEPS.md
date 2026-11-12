# Validation and next steps

Snapshot prepared November 12, 2026.

## Current state

Beta. Real cameras, background behavior and permissions require device acceptance. Configure your own signing team. No private camera addresses, recordings or live credentials are supplied.

## Validation

PASS: Swift package manifest evaluation. Native compilation, package tests, real cameras and device acceptance were not rerun for this publication.

Publication checks: the exact Git tree and its new history are scanned locally with Gitleaks before the repository becomes public. Reviewed scanner exceptions are restricted to synthetic fixture secrets, an invalid test token, a browser preference name and the published NIST AES test vector. Private histories are not included.

## Next action

Follow the README quick start, run the documented focused tests, then use isolated inputs for a manual walkthrough. Real hardware, release signing, background behavior and live-server compatibility are outside this publication check.
