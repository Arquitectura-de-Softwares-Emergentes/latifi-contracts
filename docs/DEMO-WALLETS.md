# Demo wallet pool

This runbook covers the testnet wallets behind the TB2 and TF1 demos: who they are, where their secrets live, how to fund them, how to check them before a demo and what to do when a key leaks.

Everything here runs on Polygon Amoy (chain id 80002), the testnet. The native token is POL and it has no value. Every script in `scripts/wallets/` stops with exit code 3 unless the RPC reports chain id 80002, so a wrong endpoint cannot send a transaction anywhere else.

## Why a pool

Borrowers never hold gas and never see it. The app shows a network fee and the pool covers it, as decided in the gas funding ADR (`latifi-report/docs/adr/0005-gas-funding-for-borrowers.md`). No paymaster is built. The pool is six wallets that we top up by hand with a script.

| Role | Purpose | Minimum balance |
| --- | --- | --- |
| deployer | Deploys contracts and pays the top-ups for the other five | 0.3 POL |
| lender-1 | Demo lender | 0.1 POL |
| lender-2 | Demo lender | 0.1 POL |
| borrower-1 | Demo borrower | 0.1 POL |
| borrower-2 | Demo borrower | 0.1 POL |
| borrower-3 | Demo borrower | 0.1 POL |

The public addresses and the minimums live in `deployments/demo-wallets.json`. That file holds nothing secret.

## Where the secrets live

All secrets sit in `~/.latifi` on the operator machine, in a directory with mode 700:

- `rpc.env` (mode 600) defines `AMOY_RPC_URL`.
- `keystore-password` (mode 600) holds a random password.
- `keystores/` holds one encrypted keystore per role.

Nothing under `~/.latifi` is ever committed, pasted into a chat or printed to a terminal or log. The scripts parse `rpc.env` instead of sourcing it, hand the URL to `cast` through the environment and print only the host name when they need to mention the endpoint.

The same RPC URL also lives in two GitHub repository secrets named `AMOY_RPC_URL`, one in `latifi-contracts` and one in `latifi-api`.

One limitation is accepted on purpose: the keystore password sits next to the keystores, so anyone with access to the machine can use the keys. That is fine only because the keys hold worthless testnet POL. Never use these wallets, this password or this directory layout for real value.

## One-time setup

You need Foundry (`cast`), `jq` and `openssl` on the machine.

1. Create the wallets. This makes no network call and prints addresses only:

   ```bash
   bash scripts/wallets/new-pool.sh
   ```

   It creates `~/.latifi`, a random password file and six keystores, never overwrites an existing keystore and writes `deployments/demo-wallets.json`. Commit that manifest. Do not commit anything else from this step.

2. Create a dedicated Alchemy app. In the Alchemy dashboard open Apps, choose Create new app, name it `latifi-amoy-demo` and pick the Polygon Amoy network. Do not reuse an app from another project. Copy the HTTPS URL.

3. Store the URL without echoing it. Run this in a terminal and paste the URL when the shell waits for input:

   ```bash
   mkdir -p ~/.latifi && chmod 700 ~/.latifi
   read -rs URL && printf 'AMOY_RPC_URL=%s\n' "$URL" > ~/.latifi/rpc.env && chmod 600 ~/.latifi/rpc.env
   unset URL
   ```

4. Set the repository secrets. The value goes through standard input, never through `--body`, so it stays out of the process list and the shell history:

   ```bash
   for repo in latifi-contracts latifi-api; do
     grep '^AMOY_RPC_URL=' ~/.latifi/rpc.env | cut -d= -f2- |
       gh secret set AMOY_RPC_URL --repo Arquitectura-de-Softwares-Emergentes/$repo
   done
   ```

## Getting testnet POL

Only the deployer needs a faucet claim. Aim for at least 1.0 POL: the five pool wallets take 0.1 POL each and the deployer keeps its own 0.3 POL minimum plus gas.

Print the deployer address:

```bash
jq -r '.wallets[] | select(.role=="deployer") | .address' deployments/demo-wallets.json
```

Then claim from the faucets listed in the Polygon documentation (checked on 2026-10-29, but confirm the list before you rely on it):

- Polygon faucet: https://faucet.polygon.technology/ (pick Amoy and the POL token).
- Alchemy faucet: https://www.alchemy.com/faucets/polygon-amoy. With an Alchemy account it pays 0.5 POL per day, without one only 0.2.
- QuickNode faucet: https://faucet.quicknode.com/polygon
- GetBlock faucet: https://getblock.io/faucet/matic-amoy/

Each faucet needs a login or a captcha, so this step is manual. Expect to claim over two days if you rely on the Alchemy faucet alone.

## Top-up

Check what the pool holds right now:

```bash
bash scripts/wallets/check-balances.sh          # table, exit 1 if any wallet is LOW
bash scripts/wallets/check-balances.sh --json   # same data as JSON
```

Fund the pool from the deployer. Always run the dry run first and read the plan:

```bash
bash scripts/wallets/top-up.sh --to all --amount 0.1 --dry-run
bash scripts/wallets/top-up.sh --to all --amount 0.1
bash scripts/wallets/top-up.sh --to borrower-2 --amount 0.2    # a single wallet
```

`all` means the five wallets other than the deployer. The script refuses any amount above 1 POL per transfer, refuses an unknown role, and stops if the deployer cannot cover the whole batch. It prints one transaction hash per transfer.

Exit codes for `check-balances.sh`: 0 when every wallet is at or above its minimum, 1 when at least one is LOW, 2 for bad usage or a bad manifest, 3 when the RPC is missing, unreachable or not chain id 80002.

## The 24-hour pre-gate check

Run `bash scripts/wallets/check-balances.sh` at least 24 hours before each demo gate (TB2 and TF1). It must exit 0. If it exits 1:

1. Read the table and find the LOW wallets.
2. If the deployer is LOW, claim more POL from the faucets above. Faucets can take a day, which is the reason for the 24-hour margin.
3. If a pool wallet is LOW, run `top-up.sh` for that role.
4. Run the check again and keep going until it exits 0.

Do not lower the minimums to make the check pass. The `amoy-smoke` workflow runs the same check in CI when a change to the wallet scripts or the manifest lands on `develop`, and you can start it by hand from the Actions tab.

## When the dedicated RPC is rate limited

If the Alchemy endpoint throttles you, run read-only checks against the public Amoy endpoint for the moment:

```bash
AMOY_RPC_URL=https://rpc-amoy.polygon.technology bash scripts/wallets/check-balances.sh
```

The chain id guard still applies. Use the public endpoint only for reads. Send top-ups through the dedicated endpoint once the limit clears, and check the usage tab of the Alchemy app before a demo.

## Rotation

Rotate the RPC key when the URL leaks, when someone leaves the team or before a demo if you have any doubt.

1. In the Alchemy dashboard, revoke the key or delete the app and create a new `latifi-amoy-demo` app.
2. Rewrite `~/.latifi/rpc.env` with the new URL, using the `read -rs` command from the setup section.
3. Run the two `gh secret set` commands from step 4 of the setup again.
4. Run `bash scripts/wallets/check-balances.sh` to prove the new key works.
5. If the old URL ever reached a commit, treat it as burned and also scrub the history, because revoking the key alone leaves the string public.

To rotate the wallets themselves, move the old directory aside (`mv ~/.latifi/keystores ~/.latifi/keystores.old`), run `new-pool.sh` again, commit the new manifest and fund the new deployer. The old wallets hold only testnet POL, so there is nothing to recover.
