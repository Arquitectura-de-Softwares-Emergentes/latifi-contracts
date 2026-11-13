# latifi-contracts
LatiFi smart contracts: P2P microloan lifecycle and reputation events on Polygon Amoy (Solidity, Foundry)

## Deployments

Network: Polygon Amoy (chain id 80002). Release: `v0.2.0`.

`deployments/amoy.json` is the source of truth for the addresses, the creation transactions, the constructor arguments and the ABIs. Other repositories should read it instead of copying addresses by hand.

| Contract | Address | Explorer | Sourcify |
| --- | --- | --- | --- |
| MockStablecoin | `0x66757f1Cc66B278BfC0eeFad7e3Cac1d70fd4f8B` | [Polygonscan](https://amoy.polygonscan.com/address/0x66757f1Cc66B278BfC0eeFad7e3Cac1d70fd4f8B) | [API](https://sourcify.dev/server/v2/contract/80002/0x66757f1Cc66B278BfC0eeFad7e3Cac1d70fd4f8B) |
| LoanBook | `0xcCb8ad15a4954138c987a77924ceAb468A843266` | [Polygonscan](https://amoy.polygonscan.com/address/0xcCb8ad15a4954138c987a77924ceAb468A843266) | [API](https://sourcify.dev/server/v2/contract/80002/0xcCb8ad15a4954138c987a77924ceAb468A843266) |

The deployer holds the minter role of the test token and has no power over any loan.

## Runbooks

- [Gate funding runbook](docs/GATE-RUNBOOK.md): check and top up the demo wallets in POL and test stablecoin before each gate.
- [Demo runbook](docs/DEMO-RUNBOOK.md): the on-time and late runs of the live demo and the three resilience rehearsals, with the scripts in `scripts/demo/`.
