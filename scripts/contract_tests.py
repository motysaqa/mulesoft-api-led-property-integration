#!/usr/bin/env python3
"""Contract tests for the running Experience API.

Calls a live experience-booking-channel-api and validates every response against
`experience-booking-channel-api/api-spec/openapi.yaml`. This is the check that
catches the failure MUnit cannot: the app passing its own unit tests while no
longer matching the specification a partner integrated against.

Usage:
    python scripts/contract_tests.py
    python scripts/contract_tests.py --base-url http://localhost:8080/channel/v1
    python scripts/contract_tests.py --client-id abc --client-secret def

Exit code is 0 only when every case passes, so CI can gate on it.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
import uuid
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Any

try:
    import requests
    import yaml
    from jsonschema import Draft202012Validator
except ImportError as exc:  # pragma: no cover - dependency guidance, not logic
    sys.exit(
        f"Missing dependency: {exc.name}\n"
        "Install them with: pip install -r scripts/requirements.txt"
    )

REPO_ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = REPO_ROOT / "experience-booking-channel-api" / "api-spec" / "openapi.yaml"

DEFAULT_BASE_URL = "http://localhost:8080/channel/v1"
KNOWN_PROPERTY = "PROP-1001"
UNKNOWN_PROPERTY = "PROP-DOES-NOT-EXIST"


# --------------------------------------------------------------------------- #
# OpenAPI -> JSON Schema
# --------------------------------------------------------------------------- #

def oas_to_json_schema(node: Any) -> Any:
    """Convert OpenAPI 3.0 schema dialect quirks into plain JSON Schema.

    Only one conversion actually matters here: OAS 3.0 spells "may be null" as
    `nullable: true`, which JSON Schema ignores. Without this, every optional
    price on a closed night would be reported as a contract violation.
    """
    if isinstance(node, list):
        return [oas_to_json_schema(item) for item in node]
    if not isinstance(node, dict):
        return node

    converted = {k: oas_to_json_schema(v) for k, v in node.items() if k != "nullable"}

    if node.get("nullable") is True:
        inner = {k: v for k, v in converted.items() if k not in ("description", "example")}
        keep = {k: v for k, v in converted.items() if k in ("description", "example")}
        return {**keep, "anyOf": [inner, {"type": "null"}]}

    return converted


def load_spec() -> dict:
    if not SPEC_PATH.exists():
        sys.exit(f"Specification not found at {SPEC_PATH}")
    with SPEC_PATH.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def validator_for(spec: dict, schema_name: str) -> Draft202012Validator:
    """Build a validator anchored at one component schema.

    `components` is carried along so `$ref` pointers inside the schema resolve
    against the same document, exactly as they do in the spec file.
    """
    root = copy.deepcopy(spec)
    schema = {
        "$ref": f"#/components/schemas/{schema_name}",
        "components": oas_to_json_schema(root["components"]),
    }
    return Draft202012Validator(schema)


# --------------------------------------------------------------------------- #
# Test harness
# --------------------------------------------------------------------------- #

@dataclass
class Results:
    passed: int = 0
    failures: list[str] = field(default_factory=list)

    def ok(self, name: str) -> None:
        self.passed += 1
        print(f"  PASS  {name}")

    def fail(self, name: str, detail: str) -> None:
        self.failures.append(f"{name}: {detail}")
        print(f"  FAIL  {name}\n        {detail}")


def check(results: Results, name: str, condition: bool, detail: str) -> bool:
    if condition:
        results.ok(name)
        return True
    results.fail(name, detail)
    return False


def validate_body(results: Results, name: str, validator: Draft202012Validator, body: Any) -> None:
    errors = sorted(validator.iter_errors(body), key=lambda e: list(e.path))
    if not errors:
        results.ok(name)
        return
    detail = "; ".join(
        f"{'/'.join(str(p) for p in err.path) or '<root>'}: {err.message}" for err in errors[:5]
    )
    results.fail(name, detail)


class Client:
    def __init__(self, base_url: str, client_id: str | None, client_secret: str | None,
                 token: str | None, timeout: float):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = requests.Session()
        # These headers are what API Manager's client-ID-enforcement and JWT
        # policies consume. Against a bare local app they are simply ignored.
        if client_id:
            self.session.headers["client_id"] = client_id
        if client_secret:
            self.session.headers["client_secret"] = client_secret
        if token:
            self.session.headers["Authorization"] = f"Bearer {token}"

    def get(self, path: str, correlation_id: str | None = None, **params):
        headers = {"X-Correlation-ID": correlation_id} if correlation_id else {}
        return self.session.get(
            f"{self.base_url}{path}", params=params, headers=headers, timeout=self.timeout
        )


# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #

def run(client: Client, spec: dict) -> Results:
    results = Results()
    property_list_validator = validator_for(spec, "PropertyList")
    quote_validator = validator_for(spec, "Quote")
    error_validator = validator_for(spec, "Error")

    check_in = date.today() + timedelta(days=30)
    check_out = check_in + timedelta(days=4)

    print("\n[1] health")
    response = client.get("/health")
    check(results, "health returns 200", response.status_code == 200,
          f"got {response.status_code}")

    print("\n[2] property search")
    correlation_id = str(uuid.uuid4())
    response = client.get("/properties", correlation_id=correlation_id, city="Valencia")
    if check(results, "search returns 200", response.status_code == 200,
             f"got {response.status_code}: {response.text[:200]}"):
        body = response.json()
        validate_body(results, "search body matches PropertyList", property_list_validator, body)
        check(results, "search echoes the correlation id",
              response.headers.get("X-Correlation-ID") == correlation_id,
              f"sent {correlation_id}, got {response.headers.get('X-Correlation-ID')!r}")
        check(results, "search honours the city filter",
              all(item["city"].lower() == "valencia" for item in body.get("items", [])),
              f"unexpected cities: {[i['city'] for i in body.get('items', [])]}")
        check(results, "search never returns inactive inventory",
              all(item["propertyId"] != "PROP-1006" for item in body.get("items", [])),
              "PROP-1006 is INACTIVE and must be filtered out by the process layer")

    print("\n[3] paging")
    response = client.get("/properties", pageSize=1, page=1)
    if check(results, "paged search returns 200", response.status_code == 200,
             f"got {response.status_code}"):
        body = response.json()
        validate_body(results, "paged body matches PropertyList", property_list_validator, body)
        check(results, "pageSize is respected", len(body.get("items", [])) <= 1,
              f"got {len(body.get('items', []))} items for pageSize=1")

    print("\n[4] quote")
    correlation_id = str(uuid.uuid4())
    response = client.get(
        f"/properties/{KNOWN_PROPERTY}/quote",
        correlation_id=correlation_id,
        checkIn=check_in.isoformat(),
        checkOut=check_out.isoformat(),
        guests=2,
        currency="EUR",
    )
    if check(results, "quote returns 200", response.status_code == 200,
             f"got {response.status_code}: {response.text[:300]}"):
        body = response.json()
        validate_body(results, "quote body matches Quote", quote_validator, body)
        check(results, "quote covers one night per stayed night",
              len(body.get("nightly", [])) == (check_out - check_in).days,
              f"expected {(check_out - check_in).days} nights, got {len(body.get('nightly', []))}")
        check(results, "quote echoes the correlation id",
              body.get("correlationId") == correlation_id,
              f"sent {correlation_id}, body says {body.get('correlationId')!r}")

        # Arithmetic the specification cannot express but a partner will rely on.
        totals = body.get("totals", {})
        subtotal = totals.get("subtotal", {}).get("amount", 0)
        tax = totals.get("tax", {}).get("amount", 0)
        total = totals.get("total", {}).get("amount", 0)
        check(results, "totals add up", abs((subtotal + tax) - total) < 0.01,
              f"{subtotal} + {tax} != {total}")

        priced = [n for n in body.get("nightly", []) if n.get("price")]
        nightly_sum = round(sum(n["price"]["amount"] for n in priced), 2)
        check(results, "subtotal equals the sum of sellable nights",
              abs(nightly_sum - subtotal) < 0.01 or not body.get("sellable"),
              f"nights sum to {nightly_sum}, subtotal says {subtotal}")

        check(results, "sellable agrees with the unavailable list",
              body.get("sellable") is (len(body.get("unavailableDates", [])) == 0),
              f"sellable={body.get('sellable')} but unavailableDates={body.get('unavailableDates')}")

    print("\n[5] currency conversion")
    response = client.get(
        f"/properties/{KNOWN_PROPERTY}/quote",
        checkIn=check_in.isoformat(), checkOut=check_out.isoformat(), currency="USD",
    )
    if check(results, "USD quote returns 200", response.status_code == 200,
             f"got {response.status_code}"):
        body = response.json()
        validate_body(results, "USD quote matches Quote", quote_validator, body)
        check(results, "every money object is quoted in USD",
              body.get("totals", {}).get("total", {}).get("currency") == "USD",
              f"got {body.get('totals', {}).get('total', {}).get('currency')!r}")

    print("\n[6] error contracts")
    response = client.get(
        f"/properties/{KNOWN_PROPERTY}/quote", checkIn="not-a-date", checkOut=check_out.isoformat()
    )
    if check(results, "a malformed date is rejected with 400", response.status_code == 400,
             f"got {response.status_code}"):
        validate_body(results, "400 body matches Error", error_validator, response.json())

    response = client.get(
        f"/properties/{KNOWN_PROPERTY}/quote",
        checkIn=check_out.isoformat(), checkOut=check_in.isoformat(),
    )
    check(results, "an inverted date range is rejected with 400", response.status_code == 400,
          f"got {response.status_code}")

    response = client.get(
        f"/properties/{UNKNOWN_PROPERTY}/quote",
        checkIn=check_in.isoformat(), checkOut=check_out.isoformat(),
    )
    if check(results, "an unknown property returns 404", response.status_code == 404,
             f"got {response.status_code}"):
        validate_body(results, "404 body matches Error", error_validator, response.json())

    response = client.get("/does-not-exist")
    check(results, "an undefined path returns 404", response.status_code == 404,
          f"got {response.status_code}")

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL,
                        help=f"Experience API base URL (default: {DEFAULT_BASE_URL})")
    parser.add_argument("--client-id", default=None, help="client_id header for API Manager")
    parser.add_argument("--client-secret", default=None, help="client_secret header for API Manager")
    parser.add_argument("--token", default=None, help="Bearer token when JWT validation is enabled")
    parser.add_argument("--timeout", type=float, default=15.0, help="Per-request timeout in seconds")
    parser.add_argument("--json", action="store_true", help="Print a machine-readable summary")
    args = parser.parse_args()

    spec = load_spec()
    client = Client(args.base_url, args.client_id, args.client_secret, args.token, args.timeout)

    print(f"Contract tests against {args.base_url}")
    print(f"Specification: {SPEC_PATH.relative_to(REPO_ROOT)}")

    try:
        results = run(client, spec)
    except requests.exceptions.ConnectionError:
        print(f"\nCould not reach {args.base_url}.")
        print("Start the mocks and the four Mule apps first - see README.md, 'How to run'.")
        return 2

    total = results.passed + len(results.failures)
    print(f"\n{results.passed}/{total} checks passed")
    for failure in results.failures:
        print(f"  - {failure}")

    if args.json:
        print(json.dumps({"passed": results.passed, "total": total,
                          "failures": results.failures}, indent=2))

    return 0 if not results.failures else 1


if __name__ == "__main__":
    sys.exit(main())
