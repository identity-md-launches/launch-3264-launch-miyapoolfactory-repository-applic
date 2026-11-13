# MiyaPool v2: audit notes

Copied from the miyamints monorepo (contracts/AUDIT-NOTES.md), the MiyaPool v2 section only. Earlier sections cover
v1 pools, vaults, collections and the registry, which are already on mainnet and not part of this repository.


Branch `contracts/miyapool-v2`. Replaces `MiyaPool` / `MiyaPoolFactory` in place. The live v1 factory (mainnet
`0x0513…efF3`) has no pools and nothing references it, so v2 is a new factory (CREATE3 label `MiyaPoolFactoryV2`,
`script/DeployMiyaPoolV2.s.sol`), with nothing to migrate. Owner decisions 2026-11-12 (second round): pool creation open
to anyone; one pool per collection with both redeem paths; random redeem = exactly 1 pool token, no fee; targeted (pick)
redeem = 1 pool token plus a fixed pick fee in IMD and/or INFER set by the creator, paid by the picker to the INFER/IMD
vault as the picker's contribution; no pool-token premium, reserve or auction; no admin, pause or upgrade; random off on
Robinhood Chain (4663) and for ERC1155. (A first draft with a pool-token premium sold for ETH in a Dutch auction was
dropped by the owner before review.)

**Accounting**, exact: `totalSupply + UNIT * pendingUnits == UNIT * heldUnits`. Pool tokens are never charged beyond 1 per
piece on either path.

**Pick fee.** `createPool(collection, imdFee, inferFee)`: per piece, token wei; 0 = that token not offered; both 0 = free
picks. The pool reads the vault, IMD and INFER from the factory (the factory reads `vault.imd()` / `vault.infer()` live
when a pool is created; since the launch review of 2026-11-13 its constructor stores the vault address without reading
it, so it deploys on a chain where the vault has no code, see ADAPTATION.md) and, at creation, requires each nonzero fee's token to be a registry payment token
(`vault.registry().isPaymentToken`) and the fee to be at least `vault.config().minContribution(token)` (mainnet today:
1 IMD, 3,500 INFER). Fixed forever. `redeem(ids, amounts, to, feeToken)`: burns 1e18 per piece, then (state already
updated) pulls `fee × pieces` of `feeToken` from the picker, checks the pool's balance grew by exactly that (no
fee-on-transfer), approves the vault for exactly that, calls `vault.receiveContribution(feeToken, fee, msg.sender)`, and
checks the pool's balance is back where it started (the vault pulled all of it; the allowance is then 0). NFT transfers
come last. The vault books the fee as the picker's pending contribution, converted with the next keeper batch into
INFER/IMD liquidity whose shares (and fees) are the picker's. A token not offered reverts `FeeTokenNotOffered`; with free
picks the fee token must be address(0). No change to the live vault or registry; the mainnet fork test pays fees in IMD
and in INFER into the live default vault and checks `pendingOf(picker, token)`.

Consequences the owner accepted or should know:
- The vault's minimums and payment-token list are owner-settable (Safe). Raising `minContribution(token)` above a
  pool's fee for what a pick pays (fee × pieces), or delisting IMD/INFER, makes picks in that token revert for that
  pool. Random redeems and the other fee token are unaffected, but ERC-1155 pools and every pool on chain 4663 have no
  random redeems: one whose only fee token is refused can't give out any NFT, ever. Nothing in the pool can adapt, by
  design (fixed fees). **Owner rule (2026-11-13): the Safe never delists IMD or INFER and never raises their
  `minContribution` while MiyaPools use them; such a change waits for a redeployed pool system.** Lowering a minimum
  is safe.
- **Picks can be blocked by random commits (known design limit, accepted for now; no fix in this release).** Any
  pending random commit locks every id deposited before it (`lockedEnd`) until it is revealed, and a commit can't be
  revealed until 2 blocks after it is sent. So anyone can front-run a pick with `commitRedeem(1)` (cost: 1 pool token,
  returned as an NFT, plus gas) to make it revert `LockedForRandomRedeem`, and a bot committing every block can keep
  picks on existing inventory blocked. Busy random traffic has the same effect. The app leaves locked ids out of picks.
  **Addition (launch review 2026-11-13):** the lock lasts until someone sends the reveal, and the committer need not:
  a 50-piece commit (about 143k gas) forces whoever wants to pick to pay a reveal of up to 50 transfers (about 1.9M gas
  with a plain collection, up to about 10M if every transfer burns its 200k cap). The app's reveal bot should reveal as
  soon as a target block is mined. See ADAPTATION.md (`c2cfa51a`).
- Anyone can create a collection's pool first and fix its fees for everyone (squatting). An absurd fee makes picks
  impossible in practice; random redeems still work for ERC-721 pools off chain 4663. **Correction (launch review
  2026-11-13):** ERC-1155 pools and every pool on chain 4663 have no random path, so a squatted pool there with an
  unpayable fee accepts deposits and can never release a unit, and the collection can never get another pool. See
  ADAPTATION.md (`4e9dcd9a`): not changed in the contracts, since the only fix is a fee ceiling, which is a fee rule for
  the owner to set; the app should not list or deposit into such pools.
- A pick now costs the vault's contribution path: about 430-540k gas on the live vault (fork), against ~80-90k for a v1
  targeted redeem. Free picks don't touch the vault.
- Random is free and picks cost a fee, so re-rolling random redeems (deposit, commit, reveal) to fish for a piece costs
  only gas; with a small pool and a meaningful fee that can be cheaper than the fee.
- The vault limits each benefactor to 16 distinct pending tokens; IMD and INFER are two of them, so a picker can't be
  blocked by that.

**Random and targeted on one pool.** Every held id of a random-enabled pool sits in the deposit-order queue, with its
position (`_positionOf`). A commit draws from `[head, queueEnd)`; reveals run in commit order and swap the picked id
with the head (as v1). While any commit is pending, positions `[0, queueEnd of the newest pending commit)` are locked for
targeted redeems (`LockedForRandomRedeem`; older commits' ranges are prefixes of the newest's). A targeted redeem may
take only ids past that point, and removes them by swapping with the tail, so no pending commit's range changes. Hence:
- a commit draws only ids deposited before it, whatever targeted redeems or deposits happen in between;
- once the seed is public nobody can take the piece a commit will get (no sniping), and the committer can't re-roll by
  taking their own pick; a commit's range never shrinks, so a reveal can't run short (no stranding), and an id leaves
  `_ids` and the queue exactly once (reveal or targeted; escrowed ids are in neither, so no double spend);
- the lock lasts from the commit (the target block isn't mined yet) until the reveal, which anyone can send from the
  block after the target block. Ids deposited after the newest pending commit stay free. A locked pick reverts before
  any fee is pulled.

Also new: a hook for an escrowed id reverts `AlreadyHeld` (in v1 a collection calling `onERC721Received` for an escrowed
id could mint a token against an NFT already owed to its recipient).

Tests: `test/pools/MiyaPool.t.sol` (v1's ported; fees at and below the vault minimums, a minimum raised later, a
delisted token, no vault, free picks, IMD and INFER picks booked to the picker, token choice, token not offered, no
approval, a vault pulling less (`FeeNotForwarded`), a fee-on-transfer token (`FeeNotReceived`), vault refusal blocks
picks but not random, ERC1155 fee per unit, 4663, the lock in the commit block and after, fuzzed "targeted redeems can't
steer a pick", committer re-roll, full-range commit settles), `test/invariant/MiyaPoolInvariant.t.sol` (a both-paths
721 pool with both fee tokens, a 1155 pool with an INFER fee, a free 721 pool made on 4663: exact accounting, custody,
queue is a bijection onto held ids, no targeted redeem of a drawable id, every draw deposited before its commit, the
vault booked every fee to the picker who paid it, pools hold no fee tokens; fail-on-revert), `test/pools/MiyaPoolGas.t.sol`,
`test/fork/MiyaPoolV2Fork.t.sol` (the live Miyamaker drop's holders, the live default vault, fees at its live minimums).

Review focus:
- The lock rule and queue bookkeeping (`_dequeue`, the reveal swap, `_positionOf`): try to make a commit's range shrink
  or a position collide.
- `_payPickFee`: the pull, approve and vault call; the two balance checks; that no fee can stay in the pool or be paid
  for someone else; reentrancy (`redeem` is `nonReentrant`; IMD and INFER are plain ERC-20s; the vault is trusted code;
  NFT transfers happen after the fee).
- `_checkFeeToken` at creation (live reads of the vault's registry and config) and what happens when those change later.
