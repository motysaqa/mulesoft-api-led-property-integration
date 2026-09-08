# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-08

First complete version of the portfolio project.

### Added

- **System layer**
  - `system-property-api` — REST inventory backend wrapper with a canonical
    property and availability model, request validation, and nested
    `until-successful` retry with backoff.
  - `system-legacy-rates-soap-api` — Web Service Consumer over a packaged WSDL,
    converting minor-unit amounts and empty legacy elements into a canonical
    rate calendar; SOAP faults mapped to 422 separately from connectivity errors.
- **Process layer**
  - `process-availability-pricing-api` — parallel scatter-gather over both system
    APIs, an Object Store rates cache with a 300s TTL, and the
    `merge-availability-pricing.dwl` transformation (date join, month grouping,
    FX conversion, occupancy surcharge, tax, single-point rounding).
  - `FxRates.dwl` reusable DataWeave module for conversion and money formatting.
- **Experience layer**
  - `experience-booking-channel-api` — APIKit routing against a RAML 1.0
    specification, channel-manager vocabulary, and paging at the edge.
  - OpenAPI 3.0 contract in `api-spec/` for Exchange publishing and contract tests.
- **Cross-cutting** — a shared error envelope in every layer, correlation-id
  propagation end to end, and structured JSON logging via `JsonTemplateLayout`.
- **Mocks** — a .NET 8 REST property backend with fault injection
  (`?fail=timeout|500`) and a .NET 8 SOAP 1.1 rates service that also serves the
  WSDL.
- **Tests** — 8 MUnit tests for the merge transformation and 4 for the
  orchestration and error paths; `scripts/contract_tests.py` validating a live
  Experience API against the OpenAPI contract.
- **Automation** — `scripts/run-mocks.sh`, `scripts/run-tests.sh`, and a GitHub
  Actions workflow that verifies everything not requiring credentials and skips
  MUnit with an explanation when Anypoint secrets are absent.
- **Documentation** — architecture and sequence diagrams, exact API Manager
  policy settings, a setup guide with the manual steps, and a troubleshooting log.

### Known limitations

- The MUnit suites are written but have not been executed; see
  `docs/troubleshooting.md`.
- API Manager policies are documented, not applied.
- FX uses a static table and the Object Store is in-memory.

[1.0.0]: https://github.com/motysaqa/mulesoft-api-led-property-integration/releases/tag/v1.0.0
