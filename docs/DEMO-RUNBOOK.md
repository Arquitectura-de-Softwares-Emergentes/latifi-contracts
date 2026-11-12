# Demo runbook

This runbook scripts the live demo of the whole loan loop on Polygon Amoy (chain id 80002) and the three resilience rehearsals. Follow it as written. Every command can be copied. POL and tUSD on Amoy have no value.

The runbook produces the evidence for two things:

- Run A and Run B show the full loop with two real wallets and a deployed API: an on-time loan with a visible reputation gain, and a late payment with a smaller change (roadmap criterion 3 of Phase 7).
- Rehearsals R1, R2 and R3 show that the system survives a crash, an outage and a rate limited node without losing data, and that the app tells the user what happened (roadmap criterion 4 of Phase 7).

This runbook does not close the deferred verification of earlier phases (the live cycle of plan 03-08, the device checklist of Phase 5 and the human checks of Phase 6). It only adds the demo evidence on top of them.

The funding of the wallets is a separate job, see `docs/GATE-RUNBOOK.md`. Do that first.

## 1. Cast and equipment

| Item | What it is for |
| --- | --- |
| Borrower phone | Release APK from Firebase App Distribution, a wallet app with the borrower account, Amoy added to the wallet |
| Lender phone | Same APK, a wallet app with the lender account, Amoy added to the wallet |
| Laptop | Runs the scripts in `latifi-contracts` and `latifi-api`, holds the keystores and the token file |
| Screen recording | One recording per phone, started before step A1 and stopped after the last step |
| Stopwatch | One shared stopwatch, visible in both recordings |
| Keystores on the laptop | `latifi-lender`, `latifi-borrower`, `latifi-deployer` (Foundry keystores, `cast wallet list` shows them) |
| API token file | `~/.latifi/api-token`, created in section 2 |

Do not use the debug build for Run A, Run B, R1 and R2. Only R3 uses a debug build (section 7).

## 2. Pre-flight at T-60 minutes

Do these steps in order. Stop at the first one that fails and fix it.

1. The funding check of the gate exists and says `"qualifying": true`. Look in `broadcast/` of `latifi-contracts` for the newest `gate-*.json` file and read its `qualifying` field:

   ```bash
   cd latifi-contracts
   ls -t broadcast/gate-*.json | head -n 1 | xargs jq '{gate, gateAt, checkedAt, qualifying}'
   ```

2. The deployed API is healthy. In `latifi-api`, with `HOST` replaced by the public host of the API:

   ```bash
   cd latifi-api
   bash deploy/dokploy/smoke-live.sh https://HOST
   ```

   The last line must be `smoke-live: ok https://HOST`.

3. The container and the indexer run:

   ```bash
   bash deploy/dokploy/ops.sh status
   bash deploy/dokploy/indexer-status.sh
   ```

   `indexer-status.sh` must end with `indexer: running`. If it says `off` or `failing`, stop and read section 9.

4. Both phones run the release APK and are signed in. On each phone, open Profile and check that the mode reads Live, then connect the wallet. Add Amoy to each wallet app and check that it holds POL.
5. Create the API token for `verify-run.sh`. In `latifi-contracts`:

   ```bash
   cd latifi-contracts
   bash scripts/demo/api-login.sh --api-base https://HOST/api/v1 --account latifi-borrower
   ```

   The script prints `login-ok ADDRESS expiresIn=900`. cast asks for the keystore password twice (once for the address, once for the signature). The token lives 15 minutes and there is no refresh. Run it again right before each `verify-run.sh` call if more than 15 minutes passed. Any account works, the history route is readable with any valid token.

6. Note the loan book address for the commands below:

   ```bash
   BOOK=$(jq -r .contracts.LoanBook.address deployments/amoy.json)
   BORROWER=0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0
   ```

   Replace `BORROWER` with the address of the borrower wallet the phone really uses if it is not the demo borrower.

## 3. Run A: on-time loop, 10:00 or less

Goal: request, fund, repay both installments and see the reputation change, all within 10 minutes, with the numbers below. Start the stopwatch when the borrower opens the app for the first time on a clean install. If the phones are already onboarded, start it when the borrower taps Request a loan and skip the first row, then the budget of the first row is spare time.

| Mark | Owner | Action | Expected screen | Budget | Cumulative |
| --- | --- | --- | --- | --- | --- |
| A1 | Borrower | Go through the four onboarding pages, connect the wallet, sign in, save the name and the contact | Home in Live mode with a greeting | 2:30 | 2:30 |
| A2 | Borrower | Request 100 tUSD at 1000 bps for 1 day in 2 installments | The status sheet reaches Confirmed | 1:30 | 4:00 |
| A3 | Lender | Find the request in the feed (reputation chip and local currency visible), open it, fund it with approve and then fund | The status sheet reaches Confirmed twice, the loan reads Active | 2:30 | 6:30 |
| A4 | Borrower | See the funds arrive, pay installment 1, then installment 2 | Each payment reaches Confirmed | 2:30 | 9:00 |
| A5 | Both | Both phones show the loan as Repaid. The borrower opens Reputation | The score and the level changed | 0:30 | 9:30 |

The budgets add up to 9:30. The 30 seconds that remain are slack. Success needs the stopwatch at 10:00 or less when A5 ends.

Numbers to expect for a fresh borrower (policy of `latifi-api/docs/reputation-ddd.md`):

| Item | Value |
| --- | --- |
| Interest of 100 tUSD, 1000 bps, 1 day | 27397 base units |
| Total due | 100027397 base units (100.027397 tUSD) |
| Installment 1 and 2 | 50013698 and 50013699 base units |
| Score at the start | 500 |
| Score after the profile bonus | 550 |
| Score after installment 1 and 2 on time | 570, then 590 |
| Level | Building |
| On-time counter | 2 |

A borrower with earlier loans starts higher, so the score may differ. The deltas do not: each on-time installment gives plus 20. Record the real score before A1.

Right after the last confirmation, still with the stopwatch running, find the loan id on the lender phone (loan detail) and run in `latifi-contracts`:

```bash
bash scripts/demo/verify-run.sh --api-base https://HOST/api/v1 --token-file ~/.latifi/api-token \
  --book "$BOOK" --loan-id LOAN_ID --borrower "$BORROWER" --expect-on-time --evidence broadcast/verify-run-A.json
```

The last line must be `verify-run: ok loan LOAN_ID`. Record the line `mirror matched after Ns`. Success needs that wait to be 30 seconds or less, and the request must show in the lender feed within about 30 seconds of its confirmation (A2 to A3).

What `verify-run.sh` checked when it prints ok: the loan status on chain and in the API match, `totalDue` and `amountRepaid` match the chain, `installmentsPaid` matches the repayments in the history, no two history entries share the same `txHash` and `logIndex`, and every repayment of this loan is `REPAID_ON_TIME` with delta 20.

Exit codes of `verify-run.sh`: 0 ok, 1 a comparison or expectation failed, 2 bad usage or a chain other than 80002, 3 the RPC or the API is unreachable or the token is refused, 4 the API did not mirror the chain within `--wait`.

## 4. Run B: late payment

Run B shows that a late payment changes the score by less than an on-time one. It needs a loan funded 26 to 46 hours before the payment, so you stage it two days ahead.

### 4.1 Why the change is smaller

The policy gives plus 20 for an installment paid on time, minus 5 for each day late (up to minus 100 for one installment), and minus 200 for a default. This run pays the single installment 1 day late, so the change is minus 5. It is smaller in size than the plus 20 of an on-time installment and than the minus 200 of a default. A later payment grows the penalty by 5 for each extra day, up to 100. The change is therefore proportional to the delay.

### 4.2 Staging, 26 to 46 hours before the payment moment

1. Pick the payment moment (for example the gate time). Stage the loan at a time between 46 and 26 hours before it.
2. On the borrower phone, open Request a loan. Choose the amount 100 tUSD, the rate 1000 bps, the term Other with 1 day and 1 installment. Publish it and wait for Confirmed. The app form has term Other for a custom term.
3. On the lender phone, fund it (approve, then fund) and wait for Confirmed.
4. Record the loan id and the funding time in UTC (the loan detail shows it, or read `fundedAt` from `GET /loans/LOAN_ID`).
5. The single installment falls due 24 hours after funding. You need to pay it between 1 second and 24 hours after it falls due. Funding 26 to 46 hours before the payment puts the payment between 2 and 22 hours late, which counts as 1 day late.
6. Do not leave the installment unpaid for more than 7 days after the due date. After that anyone can mark the loan as defaulted and the run turns into a default.

CLI fallback for the staging, when the app cannot be used. Run it in `latifi-contracts`. cast asks for the keystore password at each send. The gas flags are the ones of `docs/DEPLOY-AMOY.md`:

```bash
export ETH_RPC_URL="$AMOY_RPC_URL"
BOOK=$(jq -r .contracts.LoanBook.address deployments/amoy.json)
TOKEN=$(jq -r .contracts.MockStablecoin.address deployments/amoy.json)
GAS="--gas-price 35gwei --priority-gas-price 30gwei"

cast send $TOKEN "approve(address,uint256)" $BOOK 100000000 --account latifi-lender $GAS
cast send $BOOK "requestLoan(uint256,uint16,uint32,uint8)" 100000000 1000 1 1 --account latifi-borrower $GAS
cast call $BOOK "loanCount()(uint256)"
cast send $BOOK "fund(uint256)" LOAN_ID --account latifi-lender $GAS
```

The `loanCount` call prints the id of the loan you just requested, if nobody else requested one in between. Check it with `cast call $BOOK "getLoan(uint256)((address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128))" LOAN_ID` and make sure the first field is the borrower address and the fifth is 1 (Open) before funding.

### 4.3 The payment

On the payment moment:

1. Confirm that it is between 24 and 48 hours after the funding time. If it is not, the days late will not be 1. Check with:

   ```bash
   cast call $BOOK "installmentDueAt(uint256,uint256)(uint256)" LOAN_ID 1
   date -u +%s
   ```

   The payment must happen between the due value plus 1 second and the due value plus 86400 seconds.
2. The borrower pays the installment in the app (Pay installment) and waits for Confirmed. CLI fallback: `AMOUNT=$(cast call $BOOK "nextInstallment(uint256)(uint256,uint256,uint256)" LOAN_ID | sed -n 3p | awk '{print $1}')`, then `cast send $TOKEN "approve(address,uint256)" $BOOK $AMOUNT --account latifi-borrower $GAS` and `cast send $BOOK "repay(uint256,uint256)" LOAN_ID $AMOUNT --account latifi-borrower $GAS`.
3. Create a fresh token if the old one expired (section 2, step 5) and run:

   ```bash
   bash scripts/demo/verify-run.sh --api-base https://HOST/api/v1 --token-file ~/.latifi/api-token \
     --book "$BOOK" --loan-id LOAN_ID --borrower "$BORROWER" --expect-late 1 --evidence broadcast/verify-run-B.json
   ```

   The last line must be `verify-run: ok loan LOAN_ID`.

Expected numbers: total due 100027397 (one installment of the whole amount), one `REPAID_LATE` entry with `daysLate` 1 and delta minus 5. The new score equals the score before the payment minus 5. If the on-time run A came first, the score goes from 590 to 585. Record the real values from the evidence file. If the payment was more than 24 hours after the due time, the entry says `daysLate` 2 and delta minus 10, and `--expect-late 1` fails. That is a staging error, not an API error, so run `--expect-late 2` to confirm it and note it.

## 5. Rehearsal R1: crash and recovery

Goal: kill the application container, see that the platform restarts it, and see that the API still agrees with the chain.

In `latifi-api`:

1. `bash deploy/dokploy/ops.sh status`. Note the UTC time that the command prints and the container state.
2. `bash deploy/dokploy/ops.sh kill`. Note the UTC time. If the platform refuses the kill call, the script prints the equivalent `docker kill` line for an SSH session and exits 5. Run that line over SSH on the VPS instead.
3. Measure the time to healthy:

   ```bash
   SECONDS=0
   until bash deploy/dokploy/smoke-live.sh https://HOST >/dev/null 2>&1; do sleep 2; done
   echo "healthy after ${SECONDS}s"
   ```

4. If the platform does not bring the container back on its own after 3 minutes, run `bash deploy/dokploy/ops.sh start` and record that the restart was manual.
5. `bash deploy/dokploy/indexer-status.sh`. It must end with `indexer: running`.
6. In `latifi-contracts`, run `verify-run.sh` for the latest loan (the loan of Run A or of the last cycle) with a fresh token. The last line must be `verify-run: ok loan LOAN_ID`, with no duplicates.

Record: the UTC times of `kill` and of the first healthy answer, the seconds to healthy, whether the restart was automatic, the verdict of `indexer-status.sh` and the `verify-run.sh` evidence file.

## 6. Rehearsal R2: outage catch-up without loss

Goal: stop the API, let the chain move, start the API again, and show that it catches up with no loss and no duplicate.

1. In `latifi-api`: `bash deploy/dokploy/ops.sh stop`. Note the UTC time. Check that `smoke-live.sh` now fails.
2. In `latifi-contracts`, run the CLI cycle while the API is down. It emits four events on the loan book (request, fund and two repayments). cast asks for the keystore passwords at each send:

   ```bash
   bash scripts/cycle.sh --rpc-url "$AMOY_RPC_URL" --deployments deployments/amoy.json \
     --lender-account latifi-lender --borrower-account latifi-borrower
   ```

   The last line is `cycle-ok`. The evidence file is `broadcast/cycle-evidence-80002.json`. Read the loan id and the block range from it:

   ```bash
   LOAN_ID=$(jq -r .loanId broadcast/cycle-evidence-80002.json)
   FROM=$(jq '[.txs[] | select(.name == "request") | .block] | min' broadcast/cycle-evidence-80002.json)
   TO=$(jq '[.txs[].block] | max' broadcast/cycle-evidence-80002.json)
   echo "loan $LOAN_ID blocks $FROM to $TO"
   ```

3. Count the events on the chain over that block range and keep the number:

   ```bash
   export ETH_RPC_URL="$AMOY_RPC_URL"
   BOOK=$(jq -r .contracts.LoanBook.address deployments/amoy.json)
   cast logs --address "$BOOK" --from-block "$FROM" --to-block "$TO" | grep -c '^- address'
   ```

   This counts every LoanBook event in the range. If another wallet used the loan book in that range, count only the events of your loan with the loan id as the second topic. Expect 4 for the loan of the cycle.
4. In `latifi-api`: `bash deploy/dokploy/ops.sh start`. Note the UTC time and wait for health with the loop of R1 step 3. Note the second when the API is healthy.
5. Create a fresh token (section 2, step 5) and run in `latifi-contracts`:

   ```bash
   bash scripts/demo/verify-run.sh --api-base https://HOST/api/v1 --token-file ~/.latifi/api-token \
     --book "$BOOK" --loan-id "$LOAN_ID" --borrower 0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0 \
     --wait 90 --expect-on-time --evidence broadcast/verify-run-R2.json
   ```

   Pass the borrower address the cycle used. The expectation is `verify-run: ok loan LOAN_ID`, and the wait in the output is 60 seconds or less from the moment the API became healthy. The history holds the repayments of the loan, no duplicate, and the loan fields equal the chain.
6. Compare: the number of events counted on the chain (4) with the history entries of the loan (the two repayments, the evidence file lists them) plus the loan status Repaid. Nothing lost means the API shows the request, the funding and the two repayments. If the indexer needs more time than the wait, run `indexer-status.sh` and read its lines, then record the finding.

Record: the UTC times of `stop`, of the cycle, of `start` and of the first healthy answer, the loan id, the block range, the event count on chain, the `waitedSeconds` of the evidence and the verdict.

## 7. Rehearsal R3: rate limited RPC

Goal: show that a rate limited node gives the app's own message and a way to recover, and that a pending payment is never sent twice. This rehearsal needs a debug APK pointed at the fault proxy. The proxy sits between the phone and the dedicated RPC. The proxy reads the RPC URL from the environment and never prints it.

### 7.1 Build and install the debug APK

The phone must not hold the release build, because both builds share the package name and have different signing keys. Uninstall the release build first. Check `local.properties` in `latifi-android`: a line `amoy.rpcUrl` would override the environment, so remove it for this build.

```bash
cd latifi-android
AMOY_RPC_URL=http://localhost:8545 LATIFI_API_BASE_URL=https://HOST/api/v1/ REOWN_PROJECT_ID=YOUR_PROJECT_ID \
  ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb reverse tcp:8545 tcp:8545
```

Use your own Reown project id, never paste it into a file in the repository. Only debug builds may talk to `localhost` in cleartext. The release build keeps cleartext off, and a guard test enforces it.

### 7.2 Start the proxy

In `latifi-contracts`, with the dedicated RPC in the environment (it comes from `~/.latifi/rpc.env`, as in `docs/DEMO-WALLETS.md`):

```bash
set -a; . ~/.latifi/rpc.env; set +a
python3 scripts/demo/rpc-fault-proxy.py --listen 127.0.0.1:8545
```

The proxy prints `rpc-fault-proxy: listening on 127.0.0.1:8545` and then one line per request with the UTC time, the JSON-RPC method, the decision (`forward` or `limited`) and the status. It never prints the upstream URL. It refuses any listen address that is not loopback.

You can also schedule a window without any control call: `--limit-after 30 --limit-for 60` turns the limit on 30 seconds after the start for 60 seconds.

### 7.3 Walk through

Keep the proxy log visible in the recording. Use the borrower phone on a loan that still has an unpaid installment (stage one with the CLI fallback of section 4.2 if needed).

| Step | Action | Expected |
| --- | --- | --- |
| R3.1 | Open the Pay screen of the loan | The installment amount and the due date show. The proxy log shows `eth_call forward 200` |
| R3.2 | In a terminal: `curl -X POST localhost:8545/__fault/on`. Note the UTC time | The answer is JSON with `"limited": true` |
| R3.3 | On the phone, reload the Pay screen with the action "Reload this screen" | The screen shows "Too many requests. Wait a moment and try again." with the reload action. The proxy log shows `limited 429` |
| R3.4 | Start a payment while the proxy is still limited and approve it in the wallet | The status sheet stays on Confirming. After a while the notice "This is taking longer than usual. Your action may still go through. Do not send it again." shows. The app sends no second payment: the wallet shows one request only. The payment itself goes through the wallet, so only the receipt reads pass the proxy |
| R3.5 | In a terminal: `curl -X POST localhost:8545/__fault/off`. Note the UTC time | The answer is JSON with `"limited": false` |
| R3.6 | Reload the Pay screen again | The installment data is back |
| R3.7 | Wait for the pending payment | It reaches Confirmed. The loan shows the new balance |

The status of the proxy at any time: `curl localhost:8545/__fault/status`.

Record the UTC times of `on` and `off`, and what each screen showed. If any screen shows another message than the one in the table, that is a finding to record in the evidence notes, not a step to skip. Receipt polling in the app stays silent by design while the node limits, so the notice in R3.4 comes from the slow transaction rule, not from the rate limit message.

When done, stop the proxy with Ctrl+C, run `adb reverse --remove tcp:8545`, uninstall the debug build and install the release build again.

## 8. Evidence capture

The recordings are the evidence. Plan 07-06 maps each clip to the requirements it covers.

| Clip | Content | Covers |
| --- | --- | --- |
| CLIP-A1 | Run A, the on-time loop, both phones and the stopwatch | The full loop and the reputation gain, see the matrix of plan 07-06 |
| CLIP-A2 | Run B, the late payment, with the `verify-run.sh` output | The proportionally smaller change, see the matrix of plan 07-06 |
| CLIP-R1 | R1 and R2, the crash and the outage rehearsals, terminal and phone | Recovery without loss, see the matrix of plan 07-06 |
| CLIP-R2 | R3, the rate limit rehearsal, phone and proxy log | The clear message and the recovery, see the matrix of plan 07-06 |

Rules for the files:

1. Name each file `CLIP-A1.mp4` and so on, plus the date in UTC, for example `CLIP-A1-2026-12-04.mp4`.
2. Compute the hash of each file and keep it next to the file:

   ```bash
   shasum -a 256 CLIP-A1-2026-12-04.mp4 | tee -a clip-hashes.txt
   ```

3. Keep the `verify-run` evidence files (`broadcast/verify-run-*.json`) and the gate funding file (`broadcast/gate-*.json`) in the same folder as the clips. These JSON files hold public data only.
4. Public data only. No private key, keystore password, API token, RPC URL or invite secret may appear in any clip or file. Before you record: close the terminal tabs that hold `~/.latifi/rpc.env` text, hide the token file, and do not run `echo` on any secret. The scripts of this runbook never print them, but your own commands might.
5. For each clip, write down in a short notes file: the start time in UTC, the loan ids, the stopwatch result, and any finding.

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The wallet does not return to the app | The wallet app lost the session or the deep link | Reconnect the wallet from the app, see item 2.3 of the device checklist |
| `verify-run.sh` exits 3 with "run scripts/demo/api-login.sh again" | The token expired (15 minutes) | Run `api-login.sh` again |
| The feed is empty although a request is confirmed | The indexer is off or failing | `bash deploy/dokploy/indexer-status.sh` in `latifi-api`, then see `docs/DEPLOY-DOKPLOY.md` |
| `verify-run.sh` exits 4 | The API did not match the chain within the wait | Run `indexer-status.sh`, then run again with a longer `--wait` and note the time |
| The dedicated RPC provider limits you (for reads) | The free tier is used up | Use the public endpoint for reads: `AMOY_RPC_URL=https://rpc-amoy.polygon.technology`. Send transactions through the dedicated one |
| The wallet shows another network | Amoy is not selected in the wallet | Select Amoy (chain id 80002) in the wallet and retry |
| `adb reverse` fails | No device is authorized | Unlock the phone, accept the USB debugging prompt and run `adb devices` |
| The debug APK cannot reach the proxy | The reverse tunnel is gone or the proxy is not running | Run `adb reverse tcp:8545 tcp:8545` again and check the proxy log |
| `api-login.sh` exits 5 | The challenge lives 5 minutes, or the signer does not match | Run it again and type the password of the right keystore |

## 10. Gate B

Gate B repeats the same runs with the final release APK of plan 07-08 and 07-09. After it, refresh the facts, the traceability matrix and the diagrams, as plan 07-12 describes.
