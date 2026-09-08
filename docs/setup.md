# Setup and manual steps

Everything that could be scaffolded from a terminal is already in the repo. What
remains needs either a licensed tool (Anypoint Studio), an Anypoint Platform
account, or a browser. The steps are in dependency order — later ones assume the
earlier ones are done.

## What is already done

- All four Mule applications, their flows, DataWeave scripts and global error handlers
- The RAML and OpenAPI specifications
- The MUnit suites and their fixtures (**written, not executed** — see below)
- Both mock backends (built and smoke-tested)
- The contract-test and helper scripts
- The GitHub Actions workflow, which degrades gracefully without credentials

## What you must do

### 1. Install the toolchain

| Tool | Version | Why |
|---|---|---|
| JDK | 17 or 21 | Mule 4.6 runtime |
| Maven | 3.8+ | Build and MUnit |
| Anypoint Studio | 7.17+ | Running the apps locally with an embedded runtime |
| .NET SDK | 8.0+ | The two mock backends |
| Python | 3.10+ | `scripts/contract_tests.py` |

```bash
python -m pip install -r scripts/requirements.txt
```

### 2. Create an Anypoint Platform account

A free trial is enough for everything in this repo.

1. Sign up at <https://anypoint.mulesoft.com/login/signup>.
2. Note your **organisation ID** (Access Management → Organization).
3. Create an environment named `Sandbox` if one does not exist.

### 3. Configure Maven for the MuleSoft repositories

Mule runtime and MUnit artifacts come from credentialed repositories. Create
`~/.m2/settings.xml` (or merge into an existing one):

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers>
    <server>
      <id>anypoint-exchange-v3</id>
      <username>${env.ANYPOINT_USERNAME}</username>
      <password>${env.ANYPOINT_PASSWORD}</password>
    </server>
    <server>
      <id>mule-ee-releases</id>
      <username>${env.ANYPOINT_USERNAME}</username>
      <password>${env.ANYPOINT_PASSWORD}</password>
    </server>
  </servers>
</settings>
```

Then export the credentials in your shell (never commit them):

```bash
export ANYPOINT_USERNAME='your-anypoint-username'
export ANYPOINT_PASSWORD='your-anypoint-password'
```

> A **connected app** (Access Management → Connected Apps, client credentials
> grant) is better than a personal username for CI. Use `~~~Client~~~` as the
> username and `clientId~?~clientSecret` as the password.

### 4. Create the local configuration files

Each module ships `config-example.yaml`. Copy each one:

```bash
for m in system-property-api system-legacy-rates-soap-api \
         process-availability-pricing-api experience-booking-channel-api; do
  cp "$m/src/main/resources/config-example.yaml" "$m/src/main/resources/config-dev.yaml"
done
```

`config-dev.yaml` is gitignored on purpose. Nothing in the example files is
secret today, but that is exactly the habit that stops the first real credential
from being committed.

### 5. Run it locally

```bash
# Terminal 1 - mock backends
scripts/run-mocks.sh start

# Anypoint Studio - import the four Maven projects, then Run As > Mule Application
#   system-property-api             :8081
#   system-legacy-rates-soap-api    :8082
#   process-availability-pricing-api:8083
#   experience-booking-channel-api  :8080

# Terminal 2 - contract tests against the running experience API
python scripts/contract_tests.py
```

### 6. Run the MUnit suites

```bash
scripts/run-tests.sh
```

**This has not been run by the author** (no Maven in the authoring environment,
and the EE artifacts need credentials). Expect to correct at least the arithmetic
in an assertion or two on the first pass; the expected values were computed by
hand and are documented in the suite's header comment. `docs/troubleshooting.md`
explains the state of play in full.

### 7. Publish the API specification to Exchange

Cannot be automated from a bare CLI without an Exchange asset identifier, so:

1. In **Design Center → Create → API specification**, name it
   `Experience API - Booking Channel`.
2. Import `experience-booking-channel-api/src/main/resources/api/experience-booking-channel-api.raml`.
3. **Publish to Exchange**, version `1.0.0`.
4. Optionally upload `experience-booking-channel-api/api-spec/openapi.yaml` as an
   additional asset file so REST-first consumers get OpenAPI.

### 8. Create the managed API and apply policies

1. **API Manager → Add API → Add new API**, select the Exchange asset.
2. Choose **Hybrid / CloudHub** as appropriate, environment `Sandbox`.
3. Apply the five policies, in the order and with the settings in
   [api-manager-policies.md](api-manager-policies.md).
4. Note the **API instance ID**; it goes in the app's `api.instance.id` property
   if you later add the autodiscovery element.

### 9. Create products and SLA tiers

1. In the Exchange asset, define the SLA tiers `Starter` (20/min) and
   `Premium` (600/min).
2. Create the two products described in
   [api-manager-policies.md](api-manager-policies.md#products-subscriptions-versions-and-revisions).
3. Request access from a second (test) application to produce a real
   `client_id`/`client_secret` pair, then re-run the contract tests through the
   managed endpoint:

```bash
python scripts/contract_tests.py \
  --base-url https://<your-api>.eu1.anypoint.mulesoft.com/channel/v1 \
  --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET"
```

### 10. Wire JWT validation to Entra ID

The JWT policy needs a real issuer. The sibling repo
(`azure-apim-secure-gateway-messaging`) walks through the Entra ID app
registration in its own `docs/setup.md`; use the same tenant and application, and
put the resulting values into the policy as described in
[api-manager-policies.md](api-manager-policies.md#3-jwt-validation).

### 11. Publish the developer portal

Follow [api-manager-policies.md](api-manager-policies.md#developer-portal).

---

## Secret management

Secure properties are **deliberately not active** in this repo: enabling them
requires an encrypted properties file and a runtime key, neither of which belongs
in a public repository. The block is present but commented out in
`system-property-api/src/main/mule/global.xml`.

To turn it on:

1. Download the [secure properties tool](https://docs.mulesoft.com/mule-runtime/latest/secure-configuration-properties)
   (`secure-properties-tool.jar`).
2. Encrypt each value:

   ```bash
   java -jar secure-properties-tool.jar string encrypt Blowfish CBC \
        "<your-16-char-key>" "the-actual-secret"
   ```

3. Put the results in `config-secure-dev.yaml` as `![ciphertext]`:

   ```yaml
   property:
     backend:
       clientSecret: "![k2h8Jk...=]"
   ```

4. Uncomment the `secure-properties:config` block in `global.xml`.
5. Pass the key at runtime, never in a file:
   - Studio: **Run Configuration → Arguments → VM arguments** → `-M-Dsecure.key=...`
   - CloudHub: **Runtime Manager → Properties**, tick *hide value*
   - CI: a GitHub Actions repository secret

6. List every secure property name in `mule-artifact.json` under
   `secureProperties` so the runtime masks it in logs and exports.

## GitHub Actions secrets

For `mvn test` to run in CI, add these under
**Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `ANYPOINT_USERNAME` | Anypoint username, or `~~~Client~~~` for a connected app |
| `ANYPOINT_PASSWORD` | Anypoint password, or `clientId~?~clientSecret` |

Without them the workflow still runs: it builds the mocks, validates every XML
and YAML file, byte-compiles the Python, and reports the MUnit step as skipped
rather than failed. See `.github/workflows/build.yml`.
