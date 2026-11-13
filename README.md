# MiyaPool v2

NFT pools for miyamints (miyamaker.com). One pool per collection. Every NFT (or ERC-1155 unit) in a pool backs exactly
1e18 pool tokens.

- **Sell in:** deposit an NFT, receive 1 pool token.
- **Random out** (ERC-721 only, not on Robinhood Chain 4663): burn 1 token now; a later block picks the NFT
  (commit-reveal, reveals in commit order, EIP-2935 history where available). No fee.
- **Pick out:** burn 1 token per NFT and pay the pool's pick fee per NFT in IMD or INFER. The fees are set by whoever
  creates the pool and fixed forever (0 = that token not offered, both 0 = free picks). The fee goes to the INFER/IMD
  alignment vault as the picker's own contribution (`receiveContribution(token, fee, picker)`). Ids a pending random
  draw could pick are locked against picking until it is revealed.

`MiyaPoolFactory(defaultVault)` is ownerless: no admin, no setter, no upgrade path. Anyone can create a collection's
one pool (`createPool(collection, imdFee, inferFee)`); it reads IMD and INFER from the vault and checks each nonzero fee
against the vault's registry and minimum at creation.

## Deployment

One contract on Ethereum mainnet: `MiyaPoolFactory`, constructor argument the live miyamints default alignment vault
`0x34bE8C25C7922B3052D1955b8E63fB97F778AA08` (its `imd()` is IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`, its
`infer()` is INFER `0x53d0eA0A685220718Dc6a0a6e4617194C6F37921`). It replaces the v1 factory
`0x05130d6B13961dc313cd2729Ae4Fd1C22b13efF3`, which has no pools. The constructor only stores the vault address (it
makes no call, so it also deploys on a chain where the vault has no code); `imd()` and `infer()` read the vault when
asked, and a pool with a nonzero fee can only be created once the vault exists at that address. Deployed through the
IdentityMD launch factory; nothing is called after deployment. See `ADAPTATION.md` for the launch review.

## Build and test

```bash
git clone --recurse-submodules <this repo> && cd miyapool-v2-contracts
forge build
forge test                                            # unit, batch, gas, invariant; the fork test skips without an RPC
REQUIRE_FORK_TESTS=true forge test --match-path 'test/fork/*'   # against the live vault (MAINNET_RPC_URL, default publicnode)
```

Compiler: solc 0.8.28, via_ir, optimizer 100 runs, cancun, `bytecode_hash = "none"`.

## Read first

`AUDIT-NOTES.md`: the design, every internal finding and its status, the risks accepted, and the owner rule on the
vault's settings (the vault owner never delists IMD/INFER or raises their minimums while pools use them).

Licence: MIT (`LICENSE`).
