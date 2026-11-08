# Deploying LatiFi to Polygon Amoy

This is the sequence you follow on your own Mac to deploy the two contracts to Polygon Amoy, verify them, record the deployment and run one full loan cycle. Every command below is meant to be copied as it is. Nobody else needs your keys, and nothing in this repository ever asks for them.

Everything runs on the Polygon Amoy testnet (chain id 80002). POL there has no value.

## 1. Purpose and safety rules

The deploy and the live cycle are the only steps that sign a transaction on a public chain. Those steps are yours, with keystores that live on your machine.

- Only you hold the deployer, lender and borrower keys. Never paste a key or a recovery phrase into a chat, an issue, a commit or a file in this repository.
- Never pass a raw key on the command line and never type a password as a flag value. Use `--account NAME` (a Foundry keystore) and type the password when the tool asks for it.
- Keystores live in `~/.foundry/keystores`, outside the repository. A password file is only for local throwaway chains.
- Never run a signing command through a remote helper, a shared shell or a tool that copies the repository to another machine. Signing happens on this Mac only.
- The scripts accept only chain ids 80002 and 31337 and compare the chain id of the endpoint with the one you asked for before they send anything.
- If you ever suspect a key leaked, stop using that wallet. These are test wallets, so replacing one costs nothing.

## 2. What is deployed and what it costs

Two contracts, in this order: `MockStablecoin` (the test dollar, six decimals) and `LoanBook` (the lending book that takes the token address in its constructor). The deploy uses about 2.17 million gas. At the 30 gwei priority fee that Amoy asks for, that is about 0.065 to 0.08 POL.

| Wallet | Public address | Keep at least |
| --- | --- | --- |
| Deployer | `0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6` | 0.15 POL |
| Lender | `0xA22412ba83539ACFd3385DA78F6214E800E865a3` | 0.05 POL |
| Borrower | `0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0` | 0.05 POL |

The live cycle costs less than 0.04 POL per wallet, and the script refuses to start when either wallet holds less than 0.05 POL. If a wallet is short, top it up with test POL before you continue: use the Polygon faucet at https://faucet.polygon.technology (choose Amoy), or send POL from another wallet you control. Read a balance with:

```bash
cast balance 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6 --ether --rpc-url https://polygon-amoy-bor-rpc.publicnode.com
```

## 3. Prerequisites

You need Foundry v1.8.7, `jq` and a checkout of this repository on `develop` at the commit named in the checklist you were given.

Option A (preferred): install Foundry natively and pin the version. Do not use an older Foundry, because Sourcify verification only works with the v2 API that v1.8.7 calls.

```bash
foundryup --install v1.8.7
forge --version
cast --version
```

Option B: Docker through OrbStack. Mount your Foundry directory so keystores persist, set `HOME=/tmp` and use `--entrypoint cast` or `--entrypoint forge`:

```bash
docker run --rm -it -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$HOME/.foundry:/tmp/.foundry" -v "$PWD:/work" -w /work \
  --entrypoint cast ghcr.io/foundry-rs/foundry:v1.8.7 --version
```

The interactive keystore import through Docker was not verified, so prefer the native install for section 4. Use Docker only if you cannot install Foundry.

Check out the repository and confirm the commit:

```bash
git clone git@github.com:Arquitectura-de-Softwares-Emergentes/latifi-contracts.git
cd latifi-contracts
git switch develop
git submodule update --init --recursive
git rev-parse HEAD
brew install jq
```

You can skip `git clone` and `brew install jq` when you already have them. Later, if Sourcify says `no match`, the output of `git rev-parse HEAD` is the first thing to compare.

## 4. Keystores

Import each key into an encrypted Foundry keystore. The tool shows a hidden prompt for the key and then asks for a new password for the keystore. Pick a password you will remember, and never write it down in the repository.

```bash
cast wallet import latifi-deployer --interactive
cast wallet address --account latifi-deployer
```

The second command asks for the keystore password and must print `0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6`. If it prints another address, you imported the wrong key. Delete `~/.foundry/keystores/latifi-deployer` and import again.

Do the same for the lender and the borrower and compare the address each time:

```bash
cast wallet import latifi-lender --interactive
cast wallet address --account latifi-lender
cast wallet import latifi-borrower --interactive
cast wallet address --account latifi-borrower
```

The lender must print `0xA22412ba83539ACFd3385DA78F6214E800E865a3` and the borrower `0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0`.

## 5. Dry runs

Both dry runs need no key and send nothing. First the in-memory run:

```bash
forge script script/Deploy.s.sol:Deploy --sender 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6
```

Then the run against a live fork of Amoy. It reads the real nonce of the deployer, so it prints the addresses the real deploy will create, and it prints a gas estimate:

```bash
export AMOY_RPC_URL=https://polygon-amoy-bor-rpc.publicnode.com
forge script script/Deploy.s.sol:Deploy --rpc-url amoy --sender 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6
```

Write down the `MockStablecoin` and `LoanBook` addresses from the output. You compare them with the real deploy in the next section. Foundry may print a warning that EIP-3855 is not supported for chain 80002. That comes from a fixed list inside Foundry and it does not mean the chain lacks the opcode. Section 11 has a one line check that asks the real node.

`AMOY_RPC_URL` is also the endpoint the cycle script uses later. The public endpoint above carries no API key. If you use a private endpoint with a key, keep it in the environment only and never in a file in the repository.

## 6. The deploy

Make sure `AMOY_RPC_URL` is exported (section 5) and the deployer holds at least 0.15 POL. Then run the deploy. Foundry asks for the keystore password:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url amoy --account latifi-deployer \
  --sender 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6 --broadcast --slow \
  --priority-gas-price 30gwei --with-gas-price 35gwei
```

Why the explicit gas flags: Amoy asks for a 30 gwei priority fee, while Foundry's own estimate is far lower. Without the flags the transactions can sit in the pool unmined. `--slow` sends one transaction at a time and waits for each receipt.

When the command ends, compare the printed addresses with the ones from the fork dry run. They must be identical. If they differ, someone else used the deployer wallet in between, so stop and ask before you go on.

If the command stops half way (a timeout, a closed laptop, a transaction that never confirms), do not start over. Run the same command again with `--resume` added at the end:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url amoy --account latifi-deployer \
  --sender 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6 --broadcast --slow \
  --priority-gas-price 30gwei --with-gas-price 35gwei --resume
```

The broadcast file lands in `broadcast/Deploy.s.sol/80002/run-latest.json`. It is ignored by git on purpose.

## 7. Verification on Sourcify

Replace the placeholders with the addresses printed by the deploy:

```bash
forge verify-contract LOANBOOK_ADDRESS src/LoanBook.sol:LoanBook --chain 80002 --verifier sourcify --watch
forge verify-contract TOKEN_ADDRESS src/MockStablecoin.sol:MockStablecoin --chain 80002 --verifier sourcify --watch
```

Each command waits until Sourcify answers. A good answer says the contract is verified. To check again later, ask the server and look at the `match` field (`exact_match` or `match` is good):

```bash
curl -s https://sourcify.dev/server/v2/contract/80002/LOANBOOK_ADDRESS | jq .match
curl -s https://sourcify.dev/server/v2/contract/80002/TOKEN_ADDRESS | jq .match
```

Sourcify reads the constructor arguments from the creation transaction, so you pass none. If the first attempt fails, repeat it with the creation transaction hash printed in the broadcast file:

```bash
forge verify-contract LOANBOOK_ADDRESS src/LoanBook.sol:LoanBook --chain 80002 --verifier sourcify --watch \
  --creation-transaction-hash CREATION_TX_HASH
```

## 8. Recording the deployment

Turn the broadcast file into the record that the other repositories read, then run the guard on it. The release tag for this deployment is `v0.2.0`.

```bash
bash scripts/record-deployment.sh broadcast/Deploy.s.sol/80002/run-latest.json v0.2.0 > deployments/amoy.json
bash scripts/check-deployment.sh
```

The guard must print `deployment-check: ok`. If it prints findings, delete `deployments/amoy.json`, fix the cause and run the first command again. The record holds public data only: addresses, transaction hashes, block numbers, constructor arguments and the ABI. Commit it on a feature branch and open a pull request into `develop` like any other change.

## 9. The live cycle

One full cycle with the demo wallets: the lender and the borrower mint test tokens, the borrower requests a loan of 100 tokens at 10 percent for 1 day in 2 installments, the lender funds it and the borrower repays both installments. The script asks for each keystore password every time it signs, about eight times in total.

```bash
bash scripts/cycle.sh --rpc-url "$AMOY_RPC_URL" --deployments deployments/amoy.json \
  --lender-account latifi-lender --borrower-account latifi-borrower
```

To read the plan before anything is sent, add `--dry-run`. It prints every command and makes no call at all.

The expected last line is `cycle-ok`. The script also writes `broadcast/cycle-evidence-80002.json` with the transaction hashes and the final state. That file holds public data only. If a step fails, the message names it and no later step runs. Running the script again creates a second loan, which is harmless.

Before it sends anything, the script reads the chain id and the POL balance of both wallets. If one wallet holds less than 0.05 POL it exits with code 4 and tells you the address and the shortfall.

## 10. Showing a default

The grace period is fixed at 7 days and a term lasts at least 1 day, so a default can only be shown by waiting. Fund a loan with one installment and a 1 day term, then come back 8 or more days later. Fund it before a gate or a demo, not during it.

```bash
BOOK=$(jq -r .contracts.LoanBook.address deployments/amoy.json)
TOKEN=$(jq -r .contracts.MockStablecoin.address deployments/amoy.json)
GAS="--gas-price 35gwei --priority-gas-price 30gwei"

cast send $TOKEN "mint(uint256)" 10000000 --account latifi-lender --rpc-url "$AMOY_RPC_URL" $GAS
cast send $TOKEN "approve(address,uint256)" $BOOK 10000000 --account latifi-lender --rpc-url "$AMOY_RPC_URL" $GAS
cast send $BOOK "requestLoan(uint256,uint16,uint32,uint8)" 10000000 1000 1 1 --account latifi-borrower --rpc-url "$AMOY_RPC_URL" $GAS
cast call $BOOK "loanCount()(uint256)" --rpc-url "$AMOY_RPC_URL"
cast send $BOOK "fund(uint256)" LOAN_ID --account latifi-lender --rpc-url "$AMOY_RPC_URL" $GAS
```

After 8 days, check that the loan is overdue by more than 7 days, then mark it. Any wallet can send `markDefaulted`:

```bash
cast call $BOOK "installmentDueAt(uint256,uint256)(uint256)" LOAN_ID 1 --rpc-url "$AMOY_RPC_URL"
cast send $BOOK "markDefaulted(uint256)" LOAN_ID --account latifi-borrower --rpc-url "$AMOY_RPC_URL" $GAS
```

The first command prints the due time in Unix seconds. The loan can be marked once the current time is more than 7 days (604800 seconds) after that value. The unit tests and `scripts/rehearse-local.sh` prove the same flow offline, including the exact boundary second.

## 11. Troubleshooting

- An `invalid opcode` on the first guarded call means the chain lacks the transient storage opcodes. Stop and report it, because the fix is a code change. The one line fallback is to swap `ReentrancyGuardTransient` for the storage based `ReentrancyGuard` and deploy again. You can ask the node before you deploy. This read-only call runs a tiny program that uses the opcodes and prints a value ending in `01` when they work:

  ```bash
  cast rpc eth_call '{"data":"0x600160015d60015c5f5260205ff3"}' latest --rpc-url "$AMOY_RPC_URL"
  ```

- An `underpriced` error, or a transaction that stays pending: run the same command again with `--resume` and keep the gas flags `--priority-gas-price 30gwei --with-gas-price 35gwei`.
- A nonce error: another transaction left the deployer in between. Read the nonce with `cast nonce 0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6 --rpc-url "$AMOY_RPC_URL"`, repeat the fork dry run in section 5 to see the new addresses and deploy again.
- `insufficient funds`: top up the wallet (section 2) and run the command again.
- Sourcify says `no match`: the working tree differs from the deployed commit. Run `git rev-parse HEAD` and `git status`, return to the commit of the deploy and verify again.
- `cycle.sh` exits with code 3: the endpoint is unreachable or it is not Amoy. Check `echo "$AMOY_RPC_URL"` points at an Amoy endpoint, and check `cast chain-id --rpc-url "$AMOY_RPC_URL"` prints 80002.

## 12. Local rehearsal

Before the real run, or any time you change a script, you can rehearse the whole flow on a private chain. The script starts a local chain inside Docker, creates throwaway keystores from the public development mnemonic of that tool, deploys with the same flag names as the real command, runs `cycle.sh` and then proves a late payment, a default after 8 days and the grace boundary:

```bash
bash scripts/rehearse-local.sh
```

It needs Docker (OrbStack works) and prints `rehearsal-ok` when every check passed. It never talks to Amoy and never touches your own keystores.
