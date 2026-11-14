// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Blocking721, MockVault, MockToken} from "../pools/MiyaPool.t.sol";

/// @dev Fixed inventory bounds the model while allowing the same ids to circulate indefinitely.
///      Ghosts derive from successful external operations and NFT custody, not pool accounting getters.
contract EscrowSequenceHandler is Test {
    uint256 public constant INVENTORY = 24;
    uint256 constant UNIT = 1e18;
    Blocking721 public nft;
    MiyaPool public pool;
    MockVault public vault;
    MockToken public imd;
    MockToken public infer;
    address[3] public actors;
    mapping(uint256 => address) public expectedEscrow;
    mapping(uint256 => bool) public expectedHeld;
    mapping(uint256 => uint256) public depositSequence;
    mapping(uint256 => uint256) public sequenceAtCommit;
    mapping(uint256 => address) public recipientAtCommit;
    mapping(uint256 => uint256) public amountAtCommit;
    mapping(address => mapping(address => uint256)) public paidBy;
    uint256 public deposits;
    uint256 public picks;
    uint256 public committed;
    uint256 public revealed;
    uint256 public escrowCreated;
    uint256 public escrowClaimed;
    uint256 public rearms;
    uint256 public violations;
    uint256 public sequence;
    uint256 public successfulActions;

    constructor() {
        imd = new MockToken("IMD");
        infer = new MockToken("INFER");
        vault = new MockVault(address(imd), address(infer));
        nft = new Blocking721();
        pool = MiyaPool(new MiyaPoolFactory(address(vault)).createPool(address(nft), UNIT, 3500 * UNIT));
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("escrow actor ", vm.toString(i)));
            imd.mint(actors[i], 1e30);
            infer.mint(actors[i], 1e30);
            vm.startPrank(actors[i]);
            nft.setApprovalForAll(address(pool), true);
            imd.approve(address(pool), type(uint256).max);
            infer.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        for (uint256 i; i < INVENTORY; ++i) {
            nft.mint(actors[i % 3], i);
            deposit(i, i % 3, i % 2 == 0);
        }
        // Refusal is transfer-specific and leaves custody truthful, like a collection blocklist.
        nft.setBlocked(actors[2]);
    }

    function _one(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = n;
    }

    function deposit(uint256 idSeed, uint256 toSeed, bool direct) public {
        uint256 id = idSeed % INVENTORY;
        address from = nft.ownerOf(id);
        if (from == address(pool)) return;
        address to = actors[toSeed % 3];
        uint256 before = pool.balanceOf(to);
        bool ok;
        vm.prank(from);
        if (direct) {
            try nft.safeTransferFrom(from, address(pool), id, abi.encode(to)) {
                ok = true;
            } catch {
                ++violations;
            }
        } else {
            try pool.deposit(_one(id), new uint256[](0), to) {
                ok = true;
            } catch {
                ++violations;
            }
        }
        if (!ok) return;
        if (pool.balanceOf(to) != before + UNIT || nft.ownerOf(id) != address(pool)) ++violations;
        expectedHeld[id] = true;
        depositSequence[id] = ++sequence;
        ++deposits;
        ++successfulActions;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        uint256 amount = bound(amountSeed, 0, pool.balanceOf(from));
        vm.prank(from);
        try pool.transfer(actors[toSeed % 3], amount) returns (bool ok) {
            if (!ok) ++violations;
        } catch {
            ++violations;
        }
        ++successfulActions;
    }

    function pick(uint256 actorSeed, uint256 idSeed, bool payInfer) external {
        address from = actors[actorSeed % 3];
        uint256 id = idSeed % INVENTORY;
        if (!expectedHeld[id] || pool.balanceOf(from) < UNIT) return;
        // Recipients 0 and 1 are never refused, so only a pending lock can reject this request.
        address recipient = actors[(actorSeed % 3) % 2];
        bool locked = pool.isLocked(id);
        address token = payInfer ? address(infer) : address(imd);
        uint256 fee = payInfer ? 3500 * UNIT : UNIT;
        vm.prank(from);
        try pool.redeem(_one(id), new uint256[](0), recipient, token) {
            if (locked || nft.ownerOf(id) != recipient) ++violations;
            expectedHeld[id] = false;
            ++picks;
            paidBy[from][token] += fee;
            ++successfulActions;
        } catch (bytes memory reason) {
            if (
                !locked
                    || keccak256(reason)
                        != keccak256(abi.encodeWithSelector(MiyaPool.LockedForRandomRedeem.selector, id))
            ) ++violations;
        }
    }

    function commit(uint256 actorSeed, uint256 recipientSeed, uint256 amountSeed) public {
        address from = actors[actorSeed % 3];
        uint256 max = pool.balanceOf(from) / UNIT;
        if (max == 0) return;
        uint256 amount = bound(amountSeed, 1, max);
        address to = actors[recipientSeed % 3];
        vm.prank(from);
        try pool.commitRedeem(amount, to) returns (uint256 c) {
            committed += amount;
            sequenceAtCommit[c] = sequence;
            recipientAtCommit[c] = to;
            amountAtCommit[c] = amount;
            ++successfulActions;
        } catch {
            ++violations;
        }
    }

    function reveal(uint256 ageSeed, bytes32 seed) public {
        uint256 c = pool.nextRevealId();
        if (c == pool.nextCommitId()) return;
        (, uint64 target, uint32 amount,) = pool.commits(c);
        // Cover immediate settlement and the BLOCKHASH window on both sides of its edge.
        uint256[5] memory ages = [uint256(1), 2, 256, 257, 8192];
        uint256 when = uint256(target) + ages[ageSeed % ages.length];
        uint256 current = vm.getBlockNumber();
        if (current < when) {
            vm.roll(when);
            current = when;
        }
        if (current - target <= 256) vm.setBlockhash(target, bytes32(uint256(seed) | 1));
        bool expired = current - target > 256;
        vm.recordLogs();
        try pool.revealRedeem(c) {}
        catch {
            ++violations;
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (expired) {
            (, uint64 newTarget, uint32 newAmount,) = pool.commits(c);
            if (pool.nextRevealId() != c || newTarget != current + 1 || newAmount != amount) ++violations;
            ++rearms;
        } else {
            uint256 found;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(pool) || logs[i].topics[0] != MiyaPool.RedeemRevealed.selector) {
                    continue;
                }
                uint256[] memory ids = abi.decode(logs[i].data, (uint256[]));
                found += ids.length;
                for (uint256 j; j < ids.length; ++j) {
                    uint256 id = ids[j];
                    if (!expectedHeld[id] || depositSequence[id] > sequenceAtCommit[c]) ++violations;
                    expectedHeld[id] = false;
                    address to = recipientAtCommit[c];
                    if (to == actors[2]) {
                        expectedEscrow[id] = to;
                        ++escrowCreated;
                        if (nft.ownerOf(id) != address(pool)) ++violations;
                    } else if (nft.ownerOf(id) != to) {
                        ++violations;
                    }
                }
            }
            if (found != amountAtCommit[c] || pool.nextRevealId() != c + 1) ++violations;
            revealed += found;
        }
        ++successfulActions;
    }

    function claim(uint256 idSeed, bool refuseAgain, bool unauthorized) public {
        uint256 id = idSeed % INVENTORY;
        address recipient = expectedEscrow[id];
        if (recipient == address(0)) return;
        address caller = unauthorized ? actors[0] : recipient;
        address to = refuseAgain ? actors[2] : actors[1];
        vm.prank(caller);
        try pool.claimEscrowed(id, to) {
            if (unauthorized || refuseAgain || nft.ownerOf(id) != to) ++violations;
            expectedEscrow[id] = address(0);
            ++escrowClaimed;
            ++successfulActions;
        } catch (bytes memory reason) {
            if (unauthorized) {
                if (bytes4(reason) != MiyaPool.NotEscrowed.selector) ++violations;
            } else if (
                !refuseAgain || keccak256(reason) != keccak256(abi.encodeWithSignature("Error(string)", "blocked"))
            ) {
                ++violations;
            }
        }
    }

    /// @dev Called only by afterInvariant (excluded from fuzz targets). Proves all liabilities can close.
    function closeAll() external {
        while (pool.nextRevealId() < pool.nextCommitId()) {
            reveal(0, keccak256("drain pending"));
            require(violations == 0, "settlement failure");
        }
        for (uint256 i = 1; i < 3; ++i) {
            uint256 amount = pool.balanceOf(actors[i]);
            vm.prank(actors[i]);
            pool.transfer(actors[0], amount);
        }
        if (pool.balanceOf(actors[0]) != 0) {
            commit(0, 0, pool.balanceOf(actors[0]) / UNIT);
            reveal(0, keccak256("drain circulating"));
        }
        for (uint256 i; i < INVENTORY; ++i) {
            claim(i, false, false);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract MiyaPoolEscrowInvariantTest is Test {
    EscrowSequenceHandler handler;
    MiyaPool pool;

    function setUp() public {
        vm.chainId(1);
        vm.roll(10000);
        handler = new EscrowSequenceHandler();
        pool = handler.pool();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.transferShares.selector;
        selectors[2] = handler.pick.selector;
        selectors[3] = handler.commit.selector;
        selectors[4] = handler.reveal.selector;
        selectors[5] = handler.claim.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_independentBackingCustodyAndFees() public view {
        assertEq(handler.violations(), 0, "unexpected success, failure, recipient or amount");
        assertEq(pool.totalSupply(), (handler.deposits() - handler.picks() - handler.committed()) * 1e18);
        assertEq(pool.pendingUnits(), handler.committed() - handler.revealed());
        assertEq(pool.heldUnits(), handler.deposits() - handler.picks() - handler.revealed());
        uint256 escrow = handler.escrowCreated() - handler.escrowClaimed();
        assertEq(handler.nft().balanceOf(address(pool)), pool.heldUnits() + escrow);
        uint256 balances;
        uint256 totalImd;
        uint256 totalInfer;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            balances += pool.balanceOf(actor);
            uint256 imdPaid = handler.paidBy(actor, address(handler.imd()));
            uint256 inferPaid = handler.paidBy(actor, address(handler.infer()));
            assertEq(handler.vault().pendingOf(actor, address(handler.imd())), imdPaid);
            assertEq(handler.vault().pendingOf(actor, address(handler.infer())), inferPaid);
            assertEq(handler.imd().balanceOf(actor) + imdPaid, 1e30);
            assertEq(handler.infer().balanceOf(actor) + inferPaid, 1e30);
            totalImd += imdPaid;
            totalInfer += inferPaid;
        }
        assertEq(pool.totalSupply(), balances);
        assertEq(handler.imd().balanceOf(address(handler.vault())), totalImd);
        assertEq(handler.infer().balanceOf(address(handler.vault())), totalInfer);
        assertEq(handler.imd().balanceOf(address(pool)), 0);
        assertEq(handler.infer().balanceOf(address(pool)), 0);
        assertEq(handler.imd().allowance(address(pool), address(handler.vault())), 0);
        assertEq(handler.infer().allowance(address(pool), address(handler.vault())), 0);
    }

    function invariant_queueEscrowAndCommitPartitions() public view {
        (uint256 head, uint256 tail) = pool.queueBounds();
        assertEq(tail - head, pool.heldUnits());
        bool[] memory seen = new bool[](tail - head);
        uint256 held;
        for (uint256 id; id < handler.INVENTORY(); ++id) {
            assertEq(pool.isHeld(id), handler.expectedHeld(id));
            assertEq(pool.escrowedTo(id), handler.expectedEscrow(id));
            bool custody = handler.nft().ownerOf(id) == address(pool);
            assertEq(custody, handler.expectedHeld(id) || handler.expectedEscrow(id) != address(0));
            if (!handler.expectedHeld(id)) {
                assertFalse(pool.isLocked(id));
                continue;
            }
            ++held;
            assertEq(handler.expectedEscrow(id), address(0), "backing and escrow overlap");
            uint256 pos = pool.queuePositionOf(id);
            assertGe(pos, head);
            assertLt(pos, tail);
            assertFalse(seen[pos - head]);
            seen[pos - head] = true;
            bool eligible;
            for (uint256 c = pool.nextRevealId(); c < pool.nextCommitId(); ++c) {
                (address recipient,, uint32 amount, uint32 end) = pool.commits(c);
                assertEq(recipient, handler.recipientAtCommit(c));
                assertEq(amount, handler.amountAtCommit(c));
                if (pos < end) eligible = true;
            }
            assertEq(pool.isLocked(id), eligible, "lock must equal union of pending draw ranges");
        }
        assertEq(held, pool.heldIdsCount());
        if (pool.nextRevealId() == pool.nextCommitId()) assertEq(pool.lockedEnd(), 0);
    }

    function afterInvariant() public {
        handler.closeAll();
        assertEq(handler.violations(), 0);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.pendingUnits(), 0);
        assertEq(pool.heldUnits(), 0);
        assertEq(pool.lockedEnd(), 0);
        assertEq(handler.nft().balanceOf(address(pool)), 0, "every remaining NFT can exit");
        assertEq(handler.escrowCreated(), handler.escrowClaimed());
    }

    /// A deterministic driver proves the less frequent handler branches are reachable before fuzzing.
    function test_handlerExercisesEscrowRearmClaimsAndRedeposit() public {
        handler.commit(0, 2, 2);
        handler.reveal(3, keccak256("expire"));
        handler.reveal(0, keccak256("settle"));
        assertEq(handler.rearms(), 1);
        assertEq(handler.escrowCreated(), 2);
        for (uint256 id; id < handler.INVENTORY(); ++id) {
            if (handler.expectedEscrow(id) == address(0)) continue;
            handler.claim(id, false, true);
            handler.claim(id, true, false);
            handler.claim(id, false, false);
            handler.deposit(id, 0, true);
        }
        assertEq(handler.escrowClaimed(), 2);
        invariant_independentBackingCustodyAndFees();
        invariant_queueEscrowAndCommitPartitions();
        afterInvariant();
    }
}
