This review adds tests to the accepted MiyaPool v2 implementation. No production contract, dependency,
configuration, fee, interface, or deployment artifact was changed. The constructor adaptation already
present in `ADAPTATION.md` was retained: the factory stores its vault and reads its tokens lazily.
The fork verifies those reads against the specified mainnet vault, IMD and INFER at block 26,409,294.

The original fork suite now reads `vm.envOr("MAINNET_RPC_URL", string(""))`, forks exactly that block,
and skips only when the variable is empty. A configured RPC failure is a failure. The added fork
suite follows the same rule. Neither suite embeds an endpoint or accepts a different fork block.
The original random-redeem fork test advances only the local simulated block header and supplies a
synthetic future hash; it does not request a different chain snapshot. The new history test reads
the actual EIP-2935 contract at the pinned block, including its 8,191-block boundary.

The five supplied invariant-discovery perspectives were applied locally, without subagents:

| Perspective | Property and evidence | Delivered coverage |
| --- | --- | --- |
| Conservation | Every successful deposit adds exactly UNIT per received unit; picks and commits burn exactly UNIT per unit. Escrow is a separate, already-burned claim (`MiyaPool.sol`, deposits, random redeems and claimEscrowed). | Independent cumulative deposit/pick/commit/reveal ghosts; actual NFT custody equals circulating backing plus pending commitments plus escrow; actual ERC-1155 balances per id and aggregate balances across actors. |
| Round trips and rounding | Integer units convert at exactly 1e18 in both directions, including duplicate ERC-1155 batch ids. | 1,000-run repeated-cycle test, maximum representable quantity, overflow rollback, fractional share transfers followed by consolidation and full exit. |
| State transitions | Only the oldest commit settles; an expired commit changes its target, not its liability or eligible inventory. Escrow can be claimed once by its recipient. | Re-arm edges, failed/unauthorized claims, recovered-id redeposit, commit and escrow ghost state, queue position bijection. |
| Adversarial profit and liveness | Failures cannot commit a partial NFT transfer, token burn, fee payment or vault contribution; refused recipients cannot block settlement. | Atomic rollback tests, callback reentrancy, caller-specific fee funding, closing every liability after each invariant sequence. |
| Queue and custody properties | A pending draw uses only eligible inventory, while every drawable id is locked against picks. | Union-of-pending-ranges lock check, direct and pull deposits, exact draw comparison with/without intervening actions, full draining. |

These are properties promised by the supplied specification or exact conservation identities, rather
than hypotheses about extra application behavior. The closed inventory handlers use three actors,
bounded inputs and independent ghost totals. They record unexpected external-call failures as
violations, so default invariant revert filtering cannot silently approve a failed operation. A
specific selector list excludes administrative harness methods, including the final drain operation.
The new campaigns each run 256 sequences of depth 96. The escrow handler also has a deterministic
exercise of expiry, escrow, rejected claims, valid claims and redeposit to demonstrate reachability.

Answers to the six review questions:

1. Backing: no new way to mint unbacked tokens, withdraw without the corresponding burn, or strand
   tracked assets was reproduced with a compliant collection. The two new invariant suites compare
   custody and liabilities independently, including escrow and per-edition balances, and drain all
   remaining liabilities after every sequence. Direct operator transfers credit the NFT owner by
   default; explicit recipient data is honored. Malformed recipient data and overflowing deposits
   roll back. Previously documented exceptions remain: a dishonest collection controls its own
   custody reports; plain ERC-721 transferFrom deposits bypass hooks; pool tokens transferred to the
   pool are not recoverable; the reserved EnumerableSet id is refused before custody changes.

2. Fairness and liveness: no new steering or queue-blocking sequence was reproduced. The new
   1,000-run metamorphic test compares exact revealed id arrays from the same snapshot after two
   distinct target blocks are mined, interleaving direct/pull deposits, tail-swapping picks and new
   commitments. It does not reproduce the draw algorithm as its oracle. Tests cover ages 256, 257,
   8,191 and 8,192, preserving locks and liabilities across re-arm and clearing them after settlement.
   The accepted block-producer influence and expiry re-roll limitations remain: re-arming an older
   expired commitment can also change the queue permutation used by later commitments whose own
   target hashes are already known, as the existing `ADAPTATION.md` explains. Absolute draw stability
   across that expiry transition is not a property claimed by this suite. The supplied
   WalletGas helper passes for one-unit and fifty-unit reveals, refusing recipients, all fifty
   transfers consuming their allowance, expired re-arm and valid history lookup.

3. Pick fees: no underpayment, duplicate payment, wrong benefactor, unauthorized payer or retained
   fee was reproduced on successful picks. New tests check duplicate ERC-1155 ids, repeated cycles,
   short live-token allowances and failed final NFT delivery. A failure after the live vault call
   restores the contribution, user allowance, balances, NFT custody and pool supply. Both live fee
   token paths pass the supplied wallet-gas comparison. Existing coverage of fee-on-transfer tokens,
   a vault pulling less, vault refusal and vault reentrancy remains in place. Donated fee balances
   are distinct from fees collected by a pick, as documented by the prior contributor.

4. Hostile callbacks and deployment: no cross-pool or vault compromise was reproduced. A recipient
   cannot reenter a guarded pool operation during ERC-1155 delivery, but can legitimately return
   some received units through the collection hook, receiving exactly the corresponding new shares.
   Empty, malformed, ambiguous and gas-burning ERC-165 responses cannot register a pool or poison
   later creation for a valid collection. Prefunding a predicted CREATE2 address does not prevent
   deployment or change its selected fees. A malicious collection's ability to lie or steal its own
   assets is the existing documented trust boundary, not a guarantee these tests assert away.

5. Griefing: no additional vector beyond the revised audit notes was reproduced. The accepted
   costs remain: fee squatting costs a pool-creation transaction and no NFT capital; a pick lock
   costs one or more temporarily burned pool tokens, returned as NFTs, plus commit gas; leaving a
   50-unit commitment unrevealed shifts up to fifty capped transfers to the party unlocking picks;
   repeated random recycling costs gas. The earlier audit's squatting and reveal-cost corrections
   are already recorded in `AUDIT-NOTES.md` and `ADAPTATION.md`; they are not newly reported here.

6. Chain 4663: random redeem is unavailable. A payable-fee ERC-721 pool can release its entire
   inventory by picks; the new ERC-1155 invariant runs on chain 4663 and drains all units after every
   sequence. It would be incorrect to claim that *every* possible pool there guarantees exit:
   unpayable creator fees or a vault later refusing its only fee token can prevent all withdrawals,
   exactly as the revised audit notes already acknowledge. No new bypass or additional lock was
   reproduced.

The existing accepted risk reproductions were retained. No new unresolved defect requiring a
`.imd-findings.json` reproduction was identified by this work. No application adaptation was made,
so the existing root `ADAPTATION.md` is unchanged.

Validation uses the assignment seed
`0x4e7d4b00ced8179bd0e912e4945e77dea4a8011b78678c8d08fb3d784b969610`.
Build and cache artifacts are confined to `test/scratch/`, which is not part of the deliverable.

Completed checks:

- `forge build`: passed with the repository's existing compiler and optimizer settings.
- `forge test`, with the seed above and MAINNET_RPC_URL present: 130 passed, 0 failed, 0 skipped.
- `REQUIRE_FORK_TESTS=true forge test --match-path 'test/fork/*'`: 8 passed, 0 failed, 0 skipped,
  all against mainnet block 26,409,294.
- Fork-only run with MAINNET_RPC_URL absent: both fork setups skipped, with no failures.
- Both new invariant campaigns: 256 runs, 24,576 handler calls each, no handler reverts.
- Both new fuzz properties: 1,000 cases each.
- The supplied WalletGas source is copied unchanged. All eight offline wallet-gas checks and both
  live-vault wallet-gas checks pass.
- Path check: every changed or added deliverable is under `test/`; no dependencies were installed.
