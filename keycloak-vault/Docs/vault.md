# Vault from zero

Vault stores secrets: passwords, tokens, and keys. An application asks Vault for a secret at runtime instead of keeping that secret in a Git file or in a Compose `.env` that people copy around.

Vault starts locked. After every restart it is locked again. Unlocking it is called unsealing. Logging in is a separate step. The keys that unseal Vault are not a username and password.

This guide uses the Vault service in `docker-compose.yml`. The last part connects Vault to the Keycloak realm built in `keycloak.md`.

## Words

| Word | Meaning |
|---|---|
| Uninitialized | Vault has never been given encryption keys. `operator init` does that once. |
| Seal | Vault forgets the encryption key in memory. Data remains on disk. The API will not read secrets. |
| Unseal key | One share of the key that opens storage. You need 3 of the 5 shares. This is not a login. |
| Root token | The first login token. It can do everything. You use it to set Vault up, then you stop using it for daily work. |
| Secret engine | A kind of storage. This guide uses KV version 2, which keeps old versions of each secret. |
| Path | The name of a secret, such as `secret/data/fx/dev`. |
| Policy | A list of paths and whether a token may read or write them. |
| Auth method | A way to log in. `token` is the root token. `oidc` is the Keycloak login. |
| OIDC | The login protocol Keycloak speaks. Vault trusts Keycloak to identify the person. |

## 1. Start Vault

From `platform/identity`, with `.env` filled in as `keycloak.md` describes:

```bash
docker compose up -d vault
docker compose exec vault vault status
```

A new server prints:

```text
Initialized     false
Sealed          true
```

`Sealed: true` is normal before the first init and again after every restart.

### If init says permission denied

```text
mkdir /vault/data/core: permission denied
```

The data folder was created as root, and Vault's user (`100`) could not write it. Fix the owner, then init:

```bash
docker compose exec -u root vault chown -R 100:1000 /vault/data
```

`user: "0:0"` on the Vault service avoids that on the next recreate. `disable_mlock` is already set in `vault.hcl`, so Vault does not need to lock memory.

## 2. Initialize once

```bash
docker compose exec vault vault operator init
```

Vault prints five unseal keys and one initial root token. It prints them only this time. Copy the whole block into a password manager. Do not put it in Git, chat, or `.env`.

```text
Unseal Key 1: ...
Unseal Key 2: ...
Unseal Key 3: ...
Unseal Key 4: ...
Unseal Key 5: ...
Initial Root Token: hvs....
```

| Secret | What it does |
|---|---|
| Unseal key | Opens the storage. Any 3 of the 5 work. |
| Root token | Logs you in. It starts with `hvs.` |

If `operator init` says the vault is already initialized, do not run it again. Unseal with the keys you already saved. A second init is impossible without deleting the data volume, and deleting the volume deletes every secret.

## 3. Unseal

Run this three times. Paste a different unseal key at each prompt:

```bash
docker compose exec vault vault operator unseal
docker compose exec vault vault operator unseal
docker compose exec vault vault operator unseal
```

Then:

```bash
docker compose exec vault vault status
```

`Sealed` must be `false`. The website can open now:

```text
http://192.168.10.176:8200
```

Use the host IP and the published port. `8200` inside the container is the same port on the host in the Compose file (`"8200:8200"`).

## 4. Log in with the root token

In the website:

1. Method: **Token**.
2. Paste the `Initial Root Token`.
3. Sign in.

On the command line, from the server:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault vault status
```

`VAULT_TOKEN` is how the CLI proves it is logged in. Each `docker compose exec` is a new shell, so you pass the token on that command. The examples below use that form. Replace `<root-token>` with the `hvs.` value.

## 5. Seal it again

Sealing locks the API. It does not delete data.

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault vault operator seal
```

`vault status` shows `Sealed: true`. Unseal with any 3 keys, the same way as section 3. Restarting the container also seals Vault. Nobody should have to run `operator init` after a reboot.

Unseal it again before you continue. The next commands fail while Vault is sealed.

## 6. Turn on a secret store

A production Vault does not start with a secret engine. Enable KV version 2 at the path `secret`:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault vault secrets enable -path=secret kv-v2
```

Write a secret:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault kv put secret/fx/dev db_password=example-only
```

Read it back:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault kv get secret/fx/dev
```

The website shows the same record under **Secrets**, engine **secret**, path `fx/dev`.

KV version 2 stores data under `secret/data/...` and metadata under `secret/metadata/...`. When you type `vault kv put secret/fx/dev`, the `kv` command adds `data` for you. Policies must mention `secret/data/` and `secret/metadata/` themselves. That difference is the usual reason a policy looks right and still returns permission denied.

## 7. Add a policy before you trust Keycloak

A policy is a text file of paths. Create one for the platform group and a smaller one for developers.

On the server, still in `platform/identity`:

```bash
cat > /tmp/platform-admin.hcl <<'EOF'
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
path "secret/metadata" {
  capabilities = ["list"]
}
EOF

cat > /tmp/developers.hcl <<'EOF'
path "secret/data/fx/dev" {
  capabilities = ["read"]
}
path "secret/metadata/fx/dev" {
  capabilities = ["read"]
}
EOF
```

Load them:

```bash
docker compose cp /tmp/platform-admin.hcl vault:/tmp/platform-admin.hcl
docker compose cp /tmp/developers.hcl vault:/tmp/developers.hcl

docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault policy write platform-admin /tmp/platform-admin.hcl

docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault policy write developers /tmp/developers.hcl
```

`platform-admin` can manage every secret under `secret/`. `developers` can read only `secret/fx/dev`.

## 8. Connect Keycloak

Finish `keycloak.md` first. You need:

- realm `sadgan`
- user `ali` in group `platform-admin`
- user `dev1` in group `developers`
- client id `vault`
- the client secret
- a group mapper that adds the claim `groups`, with full group path off

Vault has to download this URL from inside the container:

```text
http://192.168.10.176:8888/realms/sadgan/.well-known/openid-configuration
```

Test that path from Vault:

```bash
docker compose exec vault \
  wget -qO- http://192.168.10.176:8888/realms/sadgan/.well-known/openid-configuration | head
```

If that fails, fix Keycloak's address before writing Vault's OIDC config. Use the same host and port that work in your browser.

### Enable the OIDC login

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault vault auth enable oidc
```

Write the connection. Replace the client secret and the host if yours differ:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write auth/oidc/config \
    oidc_discovery_url="http://192.168.10.176:8888/realms/sadgan" \
    oidc_client_id="vault" \
    oidc_client_secret="<client-secret>" \
    default_role="sadgan"
```

`oidc_discovery_url` has no `/.well-known/...` suffix. Vault adds that itself.

Write the role. `groups_claim="groups"` is the field created by the Keycloak mapper.

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write auth/oidc/role/sadgan \
    user_claim="preferred_username" \
    groups_claim="groups" \
    bound_audiences="vault" \
    allowed_redirect_uris="http://192.168.10.176:8200/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://127.0.0.1:8250/oidc/callback" \
    policies="default"
```

`policies="default"` is only a starting point. Group membership adds `platform-admin` or `developers` in the next step. The redirect URIs must be the same strings you saved on the Keycloak client.

### Map Keycloak groups to Vault policies

Vault matches the text inside the token to an external group. Create the two groups and keep the `id` each command prints:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write identity/group \
    name="platform-admin" type="external" policies="platform-admin"

docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write identity/group \
    name="developers" type="external" policies="developers"
```

Those ids go in `canonical_id` below. The other value, `mount_accessor`, is **not** something you invent and it is **not** the text `auth_oidc_PASTE`. `auth_oidc_PASTE` in the samples is only a reminder. Vault returns `invalid mount accessor` if that word is sent as-is.

Get the real accessor from this command:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault vault auth list
```

Read the **Accessor** column on the `oidc/` row. Do not copy the `token/` row.

```text
Path      Type    Accessor
----      ----    --------
oidc/     oidc    auth_oidc_a1b2c3d4    <-- copy this whole value
token/    token   auth_token_9f8e7d6c   <-- not this one
```

`auth_oidc_a1b2c3d4` above is an example. Yours will be different. Paste that accessor into both commands in place of `auth_oidc_PASTE`, and paste each group's `id` in place of `ADMIN_GROUP_ID` and `DEV_GROUP_ID`:

```bash
docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write identity/group-alias \
    name="platform-admin" \
    mount_accessor="auth_oidc_PASTE" \
    canonical_id="ADMIN_GROUP_ID"

docker compose exec -e VAULT_TOKEN=<root-token> vault \
  vault write identity/group-alias \
    name="developers" \
    mount_accessor="auth_oidc_PASTE" \
    canonical_id="DEV_GROUP_ID"
```

Use the same `oidc/` accessor on both commands. The alias `name` is `platform-admin` only because Keycloak's mapper has full group path turned off. If the token contains `/platform-admin`, the alias name must be `/platform-admin`.

## 9. Log in through Keycloak

1. Seal is off (`Sealed: false`).
2. Open a private browser window to `http://192.168.10.176:8200`.
3. Choose **OIDC**.
4. Role: `sadgan`.
5. Sign in with `ali` and the Keycloak password.

The browser goes to Keycloak on port 8888, then back to Vault on port 8200. The Vault home page shows the token and the policies `default` and `platform-admin`.

Sign out. In another private window, sign in as `dev1`. That token should have `developers` and should be able to read `secret/fx/dev` only.

Command-line login, on a machine that can open a browser:

```bash
export VAULT_ADDR=http://192.168.10.176:8200
vault login -method=oidc role=sadgan
```

This uses the redirect `http://127.0.0.1:8250/oidc/callback`. That URI is already in both the Keycloak client and the Vault role.

## 10. How a request moves

```text
ali opens Vault
  -> Vault sends the browser to Keycloak realm sadgan
    -> ali enters the Keycloak password
      -> Keycloak redirects to Vault with a code
        -> Vault exchanges the code, using client id vault and the client secret
          -> token field groups contains platform-admin
            -> group alias platform-admin attaches policy platform-admin
```

Keycloak never sees the value of `secret/fx/dev`. Vault never sees ali's password. Each side keeps its own job.

## 11. After you know SSO works

Daily administration goes through the `ali` login, not the root token.

Keep the root token for break-glass: enabling a new auth method, or recovering when Keycloak is down. A local root token still works when Keycloak does not. That is intentional.

When the container restarts:

1. `docker compose exec vault vault operator unseal` three times.
2. Do not init again.
3. Keycloak logins work again as soon as Vault is unsealed. The OIDC config is stored in Vault's data volume.

## 12. Common failures

| What you see | Cause |
|---|---|
| `permission denied` on `/vault/data/core` | The data directory is owned by root. `chown 100:1000` it, or run the service as `user: "0:0"`. |
| `Vault is sealed` | Unseal with 3 keys. A restart seals it. |
| Redirect URI mismatch | Keycloak client and `allowed_redirect_uris` differ by a character, a port, or `localhost` versus the IP. |
| Login works and every secret returns permission denied | The group name in the token does not match the group alias, or the policy uses `secret/fx/dev` instead of `secret/data/fx/dev`. |
| Vault cannot discover Keycloak | From inside the container, `wget` the realm URL. The host and port must be the ones Keycloak actually serves. |
| `ali` has no `platform-admin` policy | The user is not in that Keycloak group, or the mapper is not in the userinfo token. |
