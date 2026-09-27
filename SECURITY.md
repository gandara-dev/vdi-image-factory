# Security Policy

Report vulnerabilities privately through GitHub Private Vulnerability Reporting
when available. Do not open a public issue containing credentials, customer
data, production paths, inventories, logs, or image artifacts.

The build pipeline handles executable packages, an operating-system ISO,
temporary WinRM credentials, and optional Optimizer code. Verify checksums, use
approved repositories, keep secrets outside source control, and isolate the
build network. MCS publication must run under a least-privilege identity from a
trusted management host.

The synthetic mode contains no production data and performs no infrastructure
changes.
