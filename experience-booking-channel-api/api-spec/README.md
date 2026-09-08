# API specifications

Two documents describe the same API.

| File | Role |
|---|---|
| `openapi.yaml` (here) | OpenAPI 3.0 contract. Published to Anypoint Exchange for REST-first consumers and used by `scripts/contract_tests.py` to validate live responses. |
| `../src/main/resources/api/experience-booking-channel-api.raml` | RAML 1.0. This is what the APIKit router loads at runtime, so it is the contract that is actually enforced on every request. |

They are kept deliberately equivalent. **A change to one must be made in the
other**, or the CI specification check in `.github/workflows/build.yml` and the
contract tests will diverge from what APIKit enforces.

Why both: APIKit's router consumes RAML, while most partner tooling and code
generators expect OpenAPI. Maintaining one and generating the other is possible
with the Anypoint CLI, but hand-maintaining a small spec is clearer than a
generation step nobody can rerun without the toolchain installed.
