# Adaptation for the IdentityMD launch

Launch: `MiyaPoolFactory` alone, on Ethereum mainnet (kind `evm_contracts`, no token, pool or distributor), constructor
argument the live miyamints default alignment vault `0x34bE8C25C7922B3052D1955b8E63fB97F778AA08`. Pools are not
deployed by the launch: the factory creates one per collection on demand. The factory has no owner, so no `$owner`
argument exists; nothing is called after deployment.

The project keeps its behaviour, interface and costs. Two source lines changed, both in `src/pools/MiyaPoolFactory.sol`,
each required by a launch rule; one is also the imported audit's reproduced medium finding. No owner, pause, setter,
fee recipient, exit path or price was added or changed.

## Changes

### 1. Factory constructor no longer reads the vault (`src/pools/MiyaPoolFactory.sol`)

Before: the constructor reverted `InvalidVault` unless `vault_` had code and answered `imd()` and `infer()` with
nonzero addresses, and stored both as immutables.

After: the constructor stores `vault_` only. `imd()` and `infer()` are views that read `vault.imd()` /
`vault.infer()` live, returning `address(0)` when the vault has no code or does not answer with an address. The
`InvalidVault` error is removed because nothing raises it any more.

Why: the launch floor (`Contracts.protected.t.sol`, `deployAll`) CREATE2-deploys the factory's init code on an empty
chain with only the chain id set and requires runtime code. The live vault has no code there, so the old constructor
reverted and the launch could not pass. The launch recipe states the rule directly: a constructor must not call another
contract or require an address to have code; check the live contract on first use. Imported audit finding `7630b635`
(medium) reproduces exactly this and is fixed by the change.

What stays the same on mainnet: creating a pool with any nonzero fee still requires vault code (`MiyaPool.NoVault`),
reads the vault's tokens, and checks the registry and minimum (`FeeTokenNotAccepted`, `FeeBelowVaultMinimum`); a pool
with both fees 0 never touches the vault, as before. The ABI is unchanged: `vault()`, `imd()`, `infer()` keep their
selectors and return types (an `address public immutable` and an `address` view are the same ABI). Pool init code and
addresses are unchanged. The one behavioural difference: the tokens are read when a pool is created rather than when the
factory is deployed, so if the vault ever answered differently, later pools would follow it (each pool still fixes
`imd`/`infer` as immutables at its creation). The live vault is an EIP-1167 clone whose tokens do not change.

Tests: `test_factory_deploysWithAVaultWithoutCodeAndReadsItLazily` (replaces `test_factory_rejectsVaultWithoutCode`,
whose expectation the launch rule forbids) in `test/pools/MiyaPool.t.sol`; `test_launch_*` in
`test/pools/MiyaPoolLaunch.t.sol`, including a replay of the floor's CREATE2 deployment on chain id 1 with the live
vault address and no vault code, the runtime size and opcode scan, and the lazy reads against a mock vault, a vault
without code and a vault answering with non-addresses. The fork test (`test/fork/MiyaPoolV2Fork.t.sol`) is unchanged
and passes against the live vault, IMD and INFER.

### 2. `predictPool` builds the init code with `bytes.concat` (`src/pools/MiyaPoolFactory.sol`)

Before: `abi.encodePacked(type(MiyaPool).creationCode, abi.encode(...))`, two dynamic values packed in a row, which
Slither's `encode-packed-collision` detector rejects and the launch pipeline refuses as written.

After: `bytes.concat(type(MiyaPool).creationCode, abi.encode(...))`. Byte-for-byte the same init code, so the
predicted address is unchanged; `test_factory_createsAndPredicts` and
`test_launch_factoryDeploysOnAnEmptyChainWithTheLiveVaultArgument` assert `predictPool` equals the created pool.

### 3. Tests and notes

- `test/pools/MiyaPool.t.sol`: `MockVault.receiveContribution` is `virtual` so a test vault can override it; the
  constructor test above replaced.
- `test/pools/MiyaPoolLaunch.t.sol` (new): launch rehearsal, reproductions of every imported finding against the code
  as it arrived (`test_known_*`, documenting accepted behaviour), and two checks from this review of the fee path
  (a vault reentering the pool from `receiveContribution`, donated fee tokens).
- `AUDIT-NOTES.md`: a dated addendum correcting the squatting reasoning and recording the lock cost shift, pointing here.
- `README.md`: the deployment paragraph says what the constructor does and does not read.

Protected paths (`foundry.toml`, `remappings.txt`, `lib/`, `.gitmodules`) are untouched. `launch.json` is not written.

## Imported audit findings

| id | severity | reproduced | action |
| --- | --- | --- | --- |
| `7630b635` factory constructor reverts on the rehearsal chain | medium | yes | fixed, change 1 |
| `4e9dcd9a` squatted pool with an unpayable fee has no exit for ERC-1155 and chain 4663 | medium | yes | not changed, see below |
| `c2cfa51a` lock griefing shifts the reveal cost to the blocked picker | low | yes | not changed, see below |
| `8e6d454a` a lying collection mints unbacked tokens in its own pool | low | yes | not changed, see below |
| `fcbb161b` sentinel id `0xfbb67fda52d4bfb8bf` cannot be deposited | info | yes | not changed, see below |
| `73f74a5c` coverage statement | info | n/a | nothing to do |

**`4e9dcd9a` (reproduced: `test_known_squattedErc1155PoolWithUnpayableFeeHasNoExit`,
`test_known_squattedRobinhoodPoolHasNoExit`).** AUDIT-NOTES accepted squatting because "random redeems still work";
that is false for ERC-1155 pools and for every pool on chain 4663, where `randomEnabled` is false. There a pool created
with an unpayable fee accepts deposits and can never release a unit, and the collection can never get another pool. No
code change: the only in-contract fix is a ceiling on the creator's fee, and the fee rules are the requester's ("0, or
at least the vault's minimum, fixed forever", no upper bound); a ceiling would also only move the problem (a fee at
any permitted ceiling can still be unpayable in practice) and would change what a creator may set. Severity is medium,
not high, because depositing requires a holder to approve and send into a pool whose fee is public, fixed and visible
in the app, and the vault, the factory and every other pool are unaffected. Recommendation to the requester: have the
app list only pools whose fees are payable (for example at most a small multiple of the vault minimum) and warn before a
deposit into an ERC-1155 or chain-4663 pool, or add a fee ceiling in a later pool system. AUDIT-NOTES is corrected.

**`c2cfa51a` (reproduced: `test_known_largeCommitShiftsTheUnlockCostToTheRevealer`).** A 50-unit commit costs the
committer one commit (142,693 gas measured) and locks every earlier id until someone sends the reveal (1,866,375 gas
measured with a plain collection; up to about 10M if every transfer burns its 200k cap). The committer gets their 50
NFTs back either way. No code change: every fix (a deposit on commit, a reveal bounty, a per-committer limit) changes
what a random redeem costs or adds a new flow, which the launch rules forbid. Recorded in AUDIT-NOTES; the app's reveal
bot should reveal as soon as the target block is mined so a picker never has to.

**`8e6d454a` (reproduced: `test_known_lyingCollectionMintsUnbackedTokensInItsOwnPoolOnly`).** A collection that lies
in `ownerOf`, or calls the ERC-1155 hooks directly, mints unbacked tokens in its own pool. The pool must trust its
collection for custody and transfers, so this is inherent to a permissionless pool; the test confirms the liar cannot
call another pool's hook, mint in another pool, or move anything in the vault. Not changed.

**`fcbb161b` (reproduced: `test_known_sentinelIdCannotBeDeposited`).** Solady's `EnumerableSetLib` reserves that id;
the hook reverts and the depositor keeps the NFT. Nothing is lost. A fix would need another set implementation (the
dependency set is protected) or an id remapping across every path, for an id no real collection uses. Not changed.

## Review of the code as it arrived (the six questions)

All on `src/pools/MiyaPool.sol` and `src/pools/MiyaPoolFactory.sol`, Solady's ERC20, EnumerableSetLib,
SafeTransferLib, ReentrancyGuard, SafeCastLib as vendored in `lib/`. Ran: `forge build --sizes`, `forge test` with the
verifier's fuzz seed (93 tests, 256-run fuzz and invariant suites), the fork test against the live vault.

1. **Backing.** Holds on every path for a compliant collection: the hooks are the only mint and are collection-only;
   the ERC-721 hook requires `ownerOf(id) == pool` and refuses escrowed and already-held ids; both redeem paths burn
   before any external call; a reveal removes an id from `_ids` and the queue once and either delivers or escrows it;
   `claimEscrowed` only moves an id already out of `_ids`. A deposit's ERC-1155 hook makes no balance check, which
   matters only for a collection that lies (`8e6d454a`). Nothing strands a unit for a compliant collection: `deposit`
   by pull and by direct `safeTransferFrom` mint the same way, and plain `transferFrom` into the pool is documented as
   untracked. Fee tokens donated to the pool are ignored by the exact-balance checks (`test_donatedFeeTokensDoNotAffectPicks`).
2. **Random fairness and liveness.** Once a commit's target block is mined its draw is fixed: deposits append past
   `queueEnd`, picks only swap positions at or past `lockedEnd` with the tail (both outside every pending range), and
   older reveals permute the prefix deterministically in commit order. A reveal's range is always at least its amount
   (commit requires `_ids.length() >= pendingUnits + amount` and only older reveals advance the head). Nothing makes a
   commit unrevealable: recipient nonzero, 50-unit cap, a 200k gas cap per transfer with a 206,250 floor (full 200k is
   forwarded under the 63/64 rule even on a cold call), a refusing recipient is escrowed, and too little gas reverts
   instead of escrowing. Re-arm after 256 blocks (8191 with EIP-2935, present on mainnet) is a re-roll the design
   documents; it also re-rolls newer pending commits, since their reveals follow the older one's permutation. The lock
   is the newest pending commit's `queueEnd`, covers every older range, and clears exactly when `nextRevealId ==
   nextCommitId`. The cost of clearing it falls on whoever reveals (`c2cfa51a`).
3. **Pick fee.** `fee x units` in checked arithmetic, pulled once from `msg.sender` after all state changes, exact
   both ways (`FeeNotReceived`, `FeeNotForwarded`), forwarded with `msg.sender` as benefactor, token must be the
   offered IMD or INFER (`address(0)` only when both fees are 0). A locked pick reverts before the pull. Reentrancy
   from the vault's `receiveContribution` into `deposit`, `redeem` or `commitRedeem` reverts
   (`test_feeVaultCannotReenterThePool`). The vault owner raising a minimum or delisting a token blocks picks in that
   token (the owner rule in AUDIT-NOTES); the fork test confirms the live vault books both fees to the picker.
4. **Hostile collections and callbacks.** The hooks and every entry point are guarded (`nonReentrant` or
   collection-only); a collection reaches only its own pool. ERC-165 detection rejects a collection claiming
   `0xffffffff` or both kinds, with a 30k gas probe. One pool per collection via `poolOf`; CREATE2 only through the
   factory with `salt = keccak(collection)`, so no squatting at the address level. A malicious collection can drain or
   freeze its own pool (`8e6d454a`) and nothing else.
5. **Front-running and griefing beyond AUDIT-NOTES.** The reveal cost shift (`c2cfa51a`); a squatter's fee on a pool
   class without random (`4e9dcd9a`); `createPool` front-running (one transaction, no capital) is the squatting
   AUDIT-NOTES already accepts. A deposit front-running a commit only adds an id to the drawable range; a pick
   front-running a pick pays the fee. No new cost-free vector found.
6. **Robinhood Chain (4663).** `randomEnabled` is false for any pool created with `block.chainid == 4663`
   (`test_robinhoodChain_poolOpensWithoutRandomRedeems`, invariant suite's 4663 pool). Every NFT there leaves only by
   pick, so a pool with free picks always lets every NFT out; one with fees depends on the fee staying payable and the
   vault accepting the token (the owner rule), and a squatted unpayable fee traps it (`4e9dcd9a`). This launch is
   mainnet only; a 4663 factory would take that chain's vault or `address(0)`.

No DELEGATECALL, CALLCODE, SELFDESTRUCT, proxy, initializer, owner, pause or setter exists. After the change:
`MiyaPool` runtime 14,173 bytes (unchanged), factory runtime 17,691 bytes, factory init code 17,831 bytes; all under
EIP-170 and the floor's 49,152-byte init limit.
