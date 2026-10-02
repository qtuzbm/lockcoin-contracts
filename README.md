# LockCoin — 10× Lock Vault

One ticket per wallet. Locked on buy. Sold at 10× by the contract.

Website: https://tenxlock.com

## How it works

1. **One ticket per wallet, fixed price.** A second ticket from the same address reverts, forever.
2. **Locked on arrival.** Coins are minted to your wallet when you buy, and every transfer between holders reverts (`LockCoin._update`). There is nothing to list, move or dump on a DEX.
3. **Sold for you at 10×.** Open positions are ordered by size. Every buy triggers settlement: whenever the largest position is worth at least ten times what it cost, the vault burns it and pays its owner in the same transaction. Settlement is also permissionless — anyone can call `settle()`.
4. **Exit any time** at the current curve price with `exitMin(minOut)`, which reverts instead of paying less than `minOut`.
5. **No owner.** Ticket price, target multiple, lock period and virtual reserve are constructor arguments. There is no admin function, no tax, no pause switch and no withdrawal backdoor. Coins can only be minted by the vault, and only when someone buys — there is no team allocation.

Each ticket also buys and burns the Pons token (`burnBps`, 15% on the Robinhood Chain deployment).

## The arithmetic

Every 10× payout costs ten tickets, so money in = money out + pool balance + native spent on burns.
At most 1 ticket in 10 can ever exit at 10×, and only if nobody sells back to the curve earlier.
`solvent()` returns the identity and the balance check on-chain at any block.

## Deployments

| Network | Vault | Version | Source |
|---|---|---|---|
| Robinhood Chain Testnet (46630) | [`0xAFde9EFc0C21bE5b7FA24De0A3656f2C45981f8F`](https://explorer.testnet.chain.robinhood.com/address/0xAFde9EFc0C21bE5b7FA24De0A3656f2C45981f8F?tab=contract) | 3.2.0 | [Sourcify (exact match)](https://repo.sourcify.dev/46630/0xAFde9EFc0C21bE5b7FA24De0A3656f2C45981f8F) |
| Robinhood Chain (4663) | coming soon | 3.2.0 | will be verified on Sourcify |

## Verify it yourself

The files in `contracts/` are byte-identical to the source verified on the block explorer and on Sourcify (exact match, including the metadata hash):

```
sha256  contracts/SpiralVault.sol  743520604a61100b6c5078adf22a239dcd7a939a99f11a1e467b8b58c68422e1
sha256  contracts/LockCoin.sol     7b8c36b488da034e10fda3eb5a710483f859689643bd4577422f37da2de51843
```

Compiler: solc 0.8.28, optimizer on (200 runs), evmVersion paris, OpenZeppelin Contracts 5.6.1.

## Run the tests

```
npm install
npx hardhat test
```

`contracts/test/` holds test-only helpers: a stand-in Pons curve and receiver contracts that reject payments (used to test the pending → claim path).

## Status

Unaudited. No owner key also means nobody can patch a bug after deployment. Read the code before you send anything.

## License

MIT
