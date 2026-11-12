# Gate funding runbook

This runbook gets the demo wallets funded in test POL and test stablecoin (tUSD) before each gate, and proves it with a file. Follow it from T-7d to the demo. Every command is meant to be copied as it is.

Everything runs on Polygon Amoy (chain id 80002). POL and tUSD there have no value.

## 1. Purpose and the two gates

A demo dies on an empty wallet. The older wallet pool scripts in `scripts/wallets/` check POL only and know nothing about gates or the tUSD token. These scripts cover both assets and know the gate time:

- `scripts/gate/funding-check.sh` reads POL and tUSD of the lender, the borrower and the deployer, compares them with minimums and writes a JSON evidence file.
- `scripts/gate/top-up.sh` sends test POL or mints tUSD to fix a shortfall. It sends nothing unless you add `--execute`.

A check only counts for the gate when it runs at least 24 hours before the gate and every wallet is funded. A late run is reported as not qualifying, even when the wallets are full.

| Gate | When | What it shows |
| --- | --- | --- |
| TB2 | week 12 | First loop with a deployed API and an installable app |
| TF1 | week 15 | The hardened final demo |

Write each gate time as an ISO timestamp in UTC, for example `2026-12-04T23:00:00Z`. Call it `GATE_AT` in the commands below and replace it with the real time. If your local time is not UTC, convert it first: the script reads the letter Z as UTC and does no conversion.

## 2. Wallet roster

| Role | Public address | Why it matters |
| --- | --- | --- |
| Deployer and minter | `0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6` | Holds the minter role of the token and pays the top-ups |
| Lender | `0xA22412ba83539ACFd3385DA78F6214E800E865a3` | Funds the loans in the demo |
| Borrower | `0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0` | Requests and repays the loans |

These are the defaults of the scripts. The check must cover the wallets the demo really uses. If the live demo runs on phone wallets, pass them with `--lender` and `--borrower`:

```bash
bash scripts/gate/funding-check.sh --gate TB2 --gate-at GATE_AT \
  --lender 0xYOUR_PHONE_LENDER --borrower 0xYOUR_PHONE_BORROWER
```

The same flags exist in `top-up.sh`. A phone wallet that is not in the check is a wallet nobody verified.

## 3. Minimums and why

| Wallet | POL | tUSD | Reason |
| --- | --- | --- | --- |
| Lender | 0.30 | 500 | The principal of two staged loans (the on-time loop and the late loop) plus a buffer for a retry |
| Borrower | 0.30 | 50 | The interest of each run, plus a buffer. The principal comes from the lender |
| Deployer | 0.30 | none | It pays the top-ups and the mint transactions |

POL covers about 10 transactions per demo run at the Amoy gas flags the scripts use (35 gwei price, 30 gwei priority). That is a fraction of 0.30 POL, so the minimum leaves room for two runs and a rehearsal.

You can change a minimum with `--min-pol-lender`, `--min-pol-borrower`, `--min-pol-deployer`, `--min-tusd-lender` and `--min-tusd-borrower`. Do not lower a minimum to make a check pass.

The token limits you work inside: one `mintTo` call mints at most 10,000 tUSD, and one address can receive at most 10,000 tUSD in total, ever. The check shows this as the mint headroom of each wallet.

## 4. Timeline

| When | What you do |
| --- | --- |
| T-7d | First check and faucet claims. Faucets are slow, so you start early. If a wallet shows `NO_MINT_HEADROOM`, create a new wallet now |
| T-72h | Check again and top up whatever is short |
| T-50h | Stage the late loan, as the demo runbook explains. The staged loan needs wallets that are already funded |
| T-24h | The qualifying check. Run it before this moment, not after. Its JSON file is the evidence |
| T-2h | Final check, only to see that nothing moved. Add `--allow-late` here, because this run is expected to be late |
| T+0 | The demo |
| After the gate | Copy the evidence file of the T-24h run to the report repository |

The evidence file lands in `broadcast/gate-NAME-TIMESTAMP.json`. That folder is not committed. Keep the file from the T-24h run and note its name in the report.

## 5. Commands

Open a terminal in the `latifi-contracts` folder. You need Foundry (`cast`) and `jq`. Your RPC URL comes from `AMOY_RPC_URL` or from `~/.latifi/rpc.env`, as in `docs/DEMO-WALLETS.md`. You never type it into these commands.

### 5.1 The check

```bash
bash scripts/gate/funding-check.sh --gate TB2 --gate-at 2026-12-04T23:00:00Z
```

Use `--gate TF1` for the final gate. For a rehearsal, use any name made of letters, digits, dots, underscores and hyphens, for example `--gate REHEARSAL-1`.

The output is a table, then three lines: the lead time in whole hours before the gate, the verdict and the path of the evidence file.

### 5.2 Top up POL

Always run the dry run first and read the plan. Then add `--execute`.

```bash
bash scripts/gate/top-up.sh --what pol --to borrower --amount 0.5 --from-account latifi-deployer
bash scripts/gate/top-up.sh --what pol --to borrower --amount 0.5 --from-account latifi-deployer --execute
```

The limit is 1 POL per transfer. The sender must also keep 0.02 POL for gas.

### 5.3 Top up tUSD

```bash
bash scripts/gate/top-up.sh --what tusd --to lender --amount 500 --from-account latifi-deployer
bash scripts/gate/top-up.sh --what tusd --to lender --amount 500 --from-account latifi-deployer --execute
```

The sender must be the account that holds the minter role, which is the deployer. The limit is 10,000 tUSD per call, and the recipient must still have enough mint headroom.

`--to` takes `lender`, `borrower`, `deployer` or a plain `0x` address.

### 5.4 What cast asks you

With `--from-account`, cast asks for the keystore password at its own prompt. With `--execute` it asks twice: once to read the sender address and once to sign. Type the password both times. The scripts never see it.

## 6. Statuses and exit codes

Wallet statuses in the table and in the evidence:

| Status | Meaning | Action |
| --- | --- | --- |
| OK | POL and tUSD meet the minimums | None |
| LOW_POL | POL is below the minimum | Top up POL, section 5.2 |
| LOW_TUSD | tUSD is below the minimum | Top up tUSD, section 5.3 |
| LOW_BOTH | Both are below | Do both top-ups |
| NO_MINT_HEADROOM | The wallet is short of tUSD and cannot be minted enough any more | Use a new wallet, section 7 |

`funding-check.sh` exit codes:

| Code | Meaning | Action |
| --- | --- | --- |
| 0 | Funded and at least 24 hours before the gate: qualifying | Keep the evidence file |
| 1 | At least one wallet is short | Read the table, top up, run again |
| 2 | Bad usage | Read the error and fix the command |
| 3 | RPC missing, unreachable or not chain 80002 | Check `AMOY_RPC_URL`, see section 7 |
| 4 | Funded but fewer than 24 hours before the gate: not qualifying | See section 7, late run |

`top-up.sh` exit codes:

| Code | Meaning | Action |
| --- | --- | --- |
| 0 | Done, or the dry run is fine | Run with `--execute` after a dry run |
| 1 | A check refused the request. Nothing was signed | Read the REFUSED line |
| 2 | Bad usage, or the endpoint is not chain 80002 | Fix the command or the endpoint |
| 3 | RPC missing or unreachable | Check `AMOY_RPC_URL` |
| 5 | The send failed | Read the message, check the balance and run the dry run again |

## 7. Failure branches

1. Late run (exit 4). The wallets are funded but the run is less than 24 hours before the gate. Top up anyway so the demo works. Run the check again with `--allow-late`: it exits 0, but the evidence says `"qualifying": false`. Mark the evidence as not qualifying and tell the team. A late run never becomes qualifying, whatever flags you add.
2. No mint headroom. The wallet already received its 10,000 tUSD and cannot be minted more. Create a new wallet, fund it with POL and tUSD, and pass it with `--lender` or `--borrower`. Do it at the T-7d check, not later.
3. RPC rate limit. Read-only checks can use the public endpoint, as `docs/DEMO-WALLETS.md` describes:

   ```bash
   AMOY_RPC_URL=https://rpc-amoy.polygon.technology bash scripts/gate/funding-check.sh --gate TB2 --gate-at GATE_AT
   ```

   Send top-ups through your dedicated endpoint once the limit clears.
4. Faucet delay. Faucets can take a day, which is why the first check is 7 days out. Claim POL for the deployer first, because it pays everything else.
5. A refusal from `top-up.sh` (exit 1). The line starting with `check REFUSED` says why. A sender without the minter role needs the deployer account. A short sender needs POL first.
6. Wrong chain (exit 2 or 3). Stop. The endpoint does not answer chain id 80002. Fix `AMOY_RPC_URL` before anything else.

## 8. Safety

1. Keystore accounts are used by name. The scripts have no flag for a password or a private key, and they never read a password.
2. The password is typed at the cast prompt. Never paste it, or a key, or a recovery phrase into a chat, an issue, a commit or a file.
3. Signing happens only on this Mac. Never run a signing command through a remote helper or a shared shell.
4. The evidence file holds only public chain data: addresses, balances, the block number and the verdict. It holds no RPC URL, host, key or password, so it is safe to copy to the report.
5. The `--now` flag of the check exists for tests. An evidence file made with it says `"clockOverridden": true` and is not valid for a gate.
6. If you suspect a leak, stop using that wallet and replace it. These wallets hold only test funds.
