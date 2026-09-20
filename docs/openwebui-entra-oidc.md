# Open WebUI — Entra ID (OIDC) Integration

Single sign-on for you + your wife + your daughter, via your existing
Azure tenant. After this, Open WebUI shows a "Sign in with Microsoft"
button and the local password form is hidden.

**Scope of this doc:** OIDC only. Image generation is a separate
follow-up.

**Why OIDC and not a separate user/password:** Open WebUI's local
account model is fine for one person but awkward for a family — every
user has a separate password and there's no MFA. Entra gives you free
MFA (via Authenticator / passkeys) for everyone, password reset by you
or Microsoft, and a single audit trail for sign-ins.

---

## Pre-requisites

- [ ] Azure tenant (you have one for M365 — same one works)
- [ ] Global Admin / Application Administrator role in Entra (you almost
  certainly have this; needed to register apps)
- [ ] Access to Infisical at https://secrets.caehomelab.com with edit
  rights on `secret-management` / `prod` / `/`
- [ ] `kubectl` access to the cluster (your workstation kubeconfig)
- [ ] The Open WebUI pod running (it already is)

Total time: **~30 minutes**, including the Entra portal steps. Most of
it is clicking through portal.azure.com.

---

## Part A — Register the Open WebUI app in Entra

All steps are in **https://portal.azure.com → Microsoft Entra ID** (or
**https://entra.microsoft.com** → Applications → App registrations).

### A1. Create the app registration

1. **App registrations** → **+ New registration**
2. Fill in:
   - **Name:** `Open WebUI (homelab)`
   - **Supported account types:** *Accounts in this organizational
     directory only* (single tenant)
   - **Redirect URI:** Platform = **Web**,
     URL = `https://ai.caehomelab.com/oauth/oidc/callback`
3. Click **Register**

### A2. Note three identifiers

On the app's **Overview** page, copy these three values to a scratch
file (you'll need them in Part C):

```
Tenant ID      = <Directory (tenant) ID>
Client ID      = <Application (client) ID>
Client Secret  = <created in next step>
```

### A3. Create a client secret

1. **Certificates & secrets** → **Client secrets** → **+ New client
   secret**
2. Description: `homelab-k3s`
3. Expires: 24 months (long enough that you don't have to rotate every
   month; set a calendar reminder to rotate)
4. **Copy the Value** (not the Secret ID) immediately — it's only shown
   once

### A4. Configure app roles (for Admin / Member split)

This is what lets you promote your wife or daughter to admin later by
flipping an Entra group, without touching the Open WebUI database.

1. **App roles** → **+ Create app role**
2. Create two roles:

   | Display name | Allowed member types | Value    | Description |
   |---|---|---|---|
   | `Admin`  | Users/Groups | `Admin`  | Full admin access in Open WebUI |
   | `Member` | Users/Groups | `Member` | Regular user |

   (Leave **Do you want to enable this app role?** checked for both.
   Leave the *Value* field lowercase as shown — Open WebUI's
   `OAUTH_ADMIN_ROLES` env var does a case-sensitive string match.)

### A5. Assign the 3 users

1. Sidebar → **Enterprise applications** (NOT App registrations)
2. Find and click **Open WebUI (homelab)**
3. **Users and groups** → **+ Add user/group**
4. Add yourself, your wife, and your daughter. Assign roles:
   - **You:** Admin
   - **Wife:** Member
   - **Daughter:** Member

> ⚠️ The role assignment happens on the **Enterprise applications**
> blade, not App registrations. Easy to mix up — Entra splits the same
> app across two views.

### A6. (Optional but recommended) Require MFA for the app

1. **Enterprise applications → Open WebUI (homelab)** →
   **Properties** → set **User assignment required?** to **Yes**
   (this enforces "only the 3 of us can sign in")
2. **Conditional Access** (under Security in the Entra admin center) →
   **+ New policy**:
   - Users: *All users*
   - Cloud apps: **Open WebUI (homelab)**
   - Grant: **Require multifactor authentication**

   This is what gives your family free MFA on this app.

---

## Part B — Verify the redirect URI is correct

Go back to **App registrations → Open WebUI (homelab) →
Authentication** and confirm:

- **Web** redirect URI exactly equals
  `https://ai.caehomelab.com/oauth/oidc/callback`
- **Front-channel logout URL:** leave blank
- **Implicit grant:** both checkboxes **unchecked**

The exact path `/oauth/oidc/callback` is hard-coded in Open WebUI. If
you mistype it you'll get a "redirect_uri_mismatch" error in the
browser. The path has no trailing slash.

---

## Part C — Store the 3 secrets in Infisical

In **https://secrets.caehomelab.com**:

1. Project: **secret-management**
2. Environment: **prod**
3. Folder: **/**
4. Click **+ Add Secret** three times:

   | Secret name | Type | Value |
   |---|---|---|
   | `OPENWEBUI_OIDC_TENANT_ID`     | `Value` (string) | The Tenant ID from A2 |
   | `OPENWEBUI_OIDC_CLIENT_ID`     | `Value` (string) | The Client ID from A2 |
   | `OPENWEBUI_OIDC_CLIENT_SECRET` | `Secret` (write-only) | The Client Secret Value from A3 |

> Use **Secret** type (not plain Value) for the client secret — Entra
> client secrets are write-only on retrieval and the InfisicalSecret CR
> template uses `.Value` for everything. The difference matters for the
> audit trail; functionally both work. Either is fine.

The Infisical Kubernetes operator will pick these up within 60s and
write them to the existing K8s Secret `ai/openwebui-secrets`.

---

## Part D — Wire the env vars into Open WebUI

The K8s Secret `openwebui-secrets` is already mounted into Open WebUI
via `openwebui-secrets-sync` (the InfisicalSecret CR). After Part C
above it'll have two new keys: `OIDC_TENANT_ID` and `OIDC_CLIENT_ID`
(see Part E for why the names).

### D1. Tell the operator to sync the 3 new secrets

Edit
`clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml`
and extend the existing `openwebui-secrets-sync` block:

```yaml
  managedKubeSecretReferences:
    - secretName: openwebui-secrets
      secretNamespace: ai
      creationPolicy: Owner
      template:
        data:
          OPENAI_API_BASE_URL: "{{ .OPENWEBUI_OLLAMA_BASE_URL.Value }}"
          WEBUI_SECRET_KEY: "{{ .OPENWEBUI_SECRET_KEY.Value }}"
          # --- Entra ID OIDC (added 2026-09-20) ---
          OIDC_TENANT_ID:     "{{ .OPENWEBUI_OIDC_TENANT_ID.Value }}"
          OIDC_CLIENT_ID:     "{{ .OPENWEBUI_OIDC_CLIENT_ID.Value }}"
          OIDC_CLIENT_SECRET: "{{ .OPENWEBUI_OIDC_CLIENT_SECRET.Value }}"
          # ENABLE_LOGIN_FORM controls the cutover window:
          #   "true"  = local password form is visible (default; safe)
          #   "false" = OIDC-only; local accounts can't log in
          # Flip to "false" in Infisical ~7 days after OIDC goes live,
          # once all 3 family members have successfully signed in.
          ENABLE_LOGIN_FORM:   "true"
```

> **Why 3 separate Infisical secrets, not one combined JSON?** Each
> secret gets its own access control + audit trail, and the operator
> template uses `.Value` per-key. Single JSON would force every
> consumer to parse JSON to get one field.

Apply:

```bash
kubectl apply -f clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml
```

Watch the operator reconcile the secret (should take <60s):

```bash
kubectl get secret openwebui-secrets -n ai -o jsonpath='{.data}' \
  | python3 -c 'import sys,base64,json; d=json.load(sys.stdin); [print(f"  {k}: {len(base64.b64decode(v))} bytes") for k,v in d.items()]'
```

You should see entries for `OIDC_TENANT_ID`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `ENABLE_LOGIN_FORM`, `OPENAI_API_BASE_URL`, and
`WEBUI_SECRET_KEY`.

### D2. Add the OIDC env vars to the Open WebUI Deployment

Edit
`clusters/util-server/applications/openwebui/kustomization.yaml`
and add these env entries to the `openwebui` container (inside the
existing `env:` block):

```yaml
            # --- Entra ID OIDC (added 2026-09-20) ---
            # OAUTH_PROVIDER_URL drives Open WebUI's auto-discovery; the
            # standard Entra v2.0 well-known config lives at this path.
            # The "common" suffix works for single-tenant apps that allow
            # work/school accounts; since this app is "My org only", the
            # tenant-id discovery is what we actually need.
            - name: OAUTH_PROVIDER_URL
              value: "https://login.microsoftonline.com/$(OIDC_TENANT_ID)/v2.0/.well-known/openid-configuration"
            # Login button label
            - name: OAUTH_PROVIDER_NAME
              value: "Microsoft"
            # First-time OIDC login creates the local Open WebUI account.
            # Keep this on during the cutover window — wife/daughter
            # signing in for the first time will be auto-provisioned.
            - name: ENABLE_OAUTH_SIGNUP
              value: "true"
            # Map the Entra 'roles' claim into Open WebUI admin/member.
            # After Part A4+A5, your token carries roles: ["Admin"] and
            # the others carry roles: ["Member"].
            - name: OAUTH_ADMIN_ROLES
              value: "Admin"
            - name: OAUTH_ALLOWED_ROLES
              value: "Admin,Member"
            # Username + email claims (Entra v2.0 returns both)
            - name: OAUTH_USERNAME_CLAIM
              value: "preferred_username"
            - name: OAUTH_EMAIL_CLAIM
              value: "email"
            # ENABLE_LOGIN_FORM and the 3 OIDC secrets come from Infisical
            # via the openwebui-secrets-sync CR (see Part D1).
            - name: ENABLE_LOGIN_FORM
              valueFrom:
                secretKeyRef:
                  name: openwebui-secrets
                  key: ENABLE_LOGIN_FORM
                  optional: true
            - name: OAUTH_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: openwebui-secrets
                  key: OIDC_CLIENT_ID
            - name: OAUTH_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: openwebui-secrets
                  key: OIDC_CLIENT_SECRET
```

> The first env var, `OAUTH_PROVIDER_URL`, references `$(OIDC_TENANT_ID)`.
> Kubernetes expands `$(VAR)` from the pod's environment when the
> container starts, and OIDC_TENANT_ID comes from the same Secret via
> the `OAUTH_CLIENT_ID` env below. **Order matters in some env-var
> implementations** — Kubernetes evaluates `$(VAR)` references at pod
> start, so as long as the Secret is populated (Part C) before this
> Deployment rolls (Part D3), this works.

### D3. Roll the Deployment

```bash
./scripts/deploy-openwebui.sh
```

Watch the rollout:

```bash
kubectl rollout status deployment/openwebui -n ai --timeout=120s
```

Expect ~30s of single-replica window (the deployment has `maxSurge: 0`,
so a new pod only starts after an old one terminates — see the
`strategy:` comment in `kustomization.yaml`).

### D4. Verify the OIDC env vars landed

```bash
kubectl exec -n ai -l app=openwebui -c openwebui -- env | grep -E "^(OAUTH|OIDC|ENABLE_LOGIN_FORM|ENABLE_OAUTH)"
```

You should see all the env vars above with real values (Tenant ID will
be a GUID, Client ID will be a GUID, Client Secret will be a long
string).

---

## Part E — Verify sign-in works

### E1. First sign-in (you)

1. Open **https://ai.caehomelab.com** in a **private/incognito window**
   (so you're not auto-signed-in as the existing local admin)
2. You should see **Sign in with Microsoft** button below the username/
   password form (form still visible because `ENABLE_LOGIN_FORM=true`)
3. Click it → Entra login page → your work account → MFA prompt →
   back to Open WebUI
4. You land on the chat UI as a new user. The **Admin** app role should
   have promoted you to Open WebUI admin.

### E2. Verify admin promotion

In Open WebUI → top-right avatar → **Admin Panel** → **Users**:

- You should appear with the **Admin** badge
- Two other entries: **None** (your wife) and **None** (your daughter)

### E3. Sign in as wife and daughter

Same as E1 in separate incognito windows / different browsers. They
should sign in, get auto-created (because `ENABLE_OAUTH_SIGNUP=true`),
and appear as Member-role users.

### E4. Verify role enforcement

Sign in as your daughter and try to reach **Admin Panel** (top-right →
Admin Panel). She should see **"Access denied"** or no Admin Panel
link. If she can see it, the role wiring is broken — check that:

1. The Entra app roles are defined in App registrations → App roles
   (Part A4)
2. The assignments in Enterprise applications → Users and groups
   (Part A5) — **this is the step that's easy to skip**
3. `OAUTH_ADMIN_ROLES` exactly matches the role Value (case-sensitive
   — "Admin", not "admin")

### E5. Smoke test chat works

Send a message to one of your Ollama models via the chat UI as your
daughter. If chat works, the OIDC sign-in wired up the JWT correctly
and the OpenAI-to-Bifrost connection is intact.

---

## Part F — Lock it down (7-day cutover window)

After a week of stable OIDC sign-ins from all 3 of you, remove the
local password form so only Entra can sign in.

### F1. Disable the local form

In **Infisical**:
- Edit `secret-management` / `prod` / `/` secret `OPENWEBUI_OIDC_*` —
  actually, you edit the separate secret that holds the form flag.

The operator template currently writes `ENABLE_LOGIN_FORM: "true"`
directly. To flip it without a code change, restructure: instead of
the literal in the YAML, map `ENABLE_LOGIN_FORM` from an Infisical
secret:

```yaml
          ENABLE_LOGIN_FORM: "{{ .OPENWEBUI_LOGIN_FORM.Value }}"
```

Then add a new Infisical secret `OPENWEBUI_LOGIN_FORM` with value
`true` (during cutover) and flip it to `false` when you're ready. Add
a corresponding `valueFrom: secretKeyRef` in the Deployment.

**Simpler approach:** edit `infisical-secrets-sync.yaml` directly,
change the `ENABLE_LOGIN_FORM: "true"` to `"false"`, re-apply, and
restart Open WebUI:

```bash
kubectl apply -f clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml
kubectl rollout restart deployment/openwebui -n ai
kubectl rollout status deployment/openwebui -n ai --timeout=120s
```

### F2. Verify

Open https://ai.caehomelab.com in a fresh incognito window. You should
see **only** the "Sign in with Microsoft" button — no username/
password form. Local accounts (your pre-OIDC admin) can no longer log
in via the web UI.

**Backup access:** your local admin still exists in the Open WebUI
database. To regain access if Entra breaks, edit `ENABLE_LOGIN_FORM`
back to `"true"` and restart.

### F3. (Optional) Promote your wife to admin later

To give your wife admin later:
1. **Entra admin center → Enterprise applications → Open WebUI
   (homelab) → Users and groups**
2. Change her role from Member to Admin
3. She signs out and back in (token refresh takes ~1h otherwise)
4. She's now Open WebUI admin — no database touch, no Infisical change

---

## Part G — Rollback if something breaks

If OIDC doesn't work and you need to get back to local-only:

1. **Infisical** — no change needed (the operator hasn't touched the
   local-password path)
2. **Disable OAuth signup** by editing `infisical-secrets-sync.yaml`:
   remove the OIDC env vars from the operator template, OR set
   `ENABLE_LOGIN_FORM: "true"` if it was already false
3. **Redeploy without OIDC env vars:**
   ```bash
   # edit kustomization.yaml to remove the OAUTH_* and OIDC_* env entries
   ./scripts/deploy-openwebui.sh
   ```
4. **Verify** Open WebUI comes back with the local login form

Existing local accounts (your pre-OIDC admin) still work; OIDC-created
accounts become "orphaned" (you can delete them in Admin Panel →
Users, or leave them — they just can't log in anymore).

---

## Foot-guns

- **App roles are defined in App registrations but assigned in
  Enterprise applications.** Both blades exist for the same app. Skip
  the Enterprise applications assignment and the role claim will be
  empty — your admin will sign in as a regular user, not admin.

- **`OAUTH_ADMIN_ROLES` is case-sensitive.** Entra app role Values are
  case-sensitive strings. If you set the role Value to "admin" (lowercase)
  in Entra, set `OAUTH_ADMIN_ROLES: "admin"` here. Use the same casing
  both places.

- **Open WebUI's `OAUTH_PROVIDER_URL` env var uses `$(VAR)` expansion.**
  Kubernetes expands these at pod start, so the Secret must be
  populated BEFORE the Deployment rolls. If you do Part D2/3 before
  Part D1, the pods will fail to start with `OAUTH_PROVIDER_URL=
  https://login.microsoftonline.com//v2.0/.well-known/...` (double
  slash) — fix by re-running Part D1 and rolling again.

- **First sign-in only.** After the cutover, the OIDC button is the
  only way to log in (assuming you set `ENABLE_LOGIN_FORM=false`).
  Set a calendar reminder to rotate the Entra client secret before it
  expires (24 months from A3).

- **No MFA = no security.** Part A6 step 2 is optional but strongly
  recommended. Without it, anyone who steals your wife's password
  signs in without the Authenticator prompt. The Conditional Access
  policy is one checkbox; it costs nothing.

- **Family vs. guests.** If you want to give a friend access later,
  add them to the Enterprise application's Users and groups with the
  Member role. They don't need to be in any Azure group — just
  directly assigned. To revoke, remove them from the same list.

---

## See also

- `clusters/util-server/applications/openwebui/kustomization.yaml` —
  the Deployment these env vars get added to
- `clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml`
  — the operator CR that maps Infisical secrets → K8s Secret
- `clusters/util-server/applications/infisical-operator/README.md` —
  how the operator + Machine Identity work
- `docs/rotate-placeholder-credentials.md` — pattern for rotating the
  Entra client secret when it expires
