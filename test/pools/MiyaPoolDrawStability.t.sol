// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Mock721} from "./MiyaPool.t.sol";

/// @notice Metamorphic oracle: compare the same two committed draws from the same snapshot, with
///         arbitrary legal intervening actions. The test does not reimplement the random algorithm.
contract MiyaPoolDrawStabilityTest is Test {
    Mock721 nft;
    MiyaPool pool;
    address alice = makeAddr("draw depositor");
    address bob = makeAddr("draw recipient");
    address carol = makeAddr("later recipient");

    function setUp() public {
        vm.chainId(1);
        vm.roll(10000);
        nft = new Mock721();
        pool = MiyaPool(new MiyaPoolFactory(address(0)).createPool(address(nft), 0, 0));
        for (uint256 id; id < 16; ++id) {
            nft.mint(alice, id);
        }
        vm.prank(alice);
        nft.setApprovalForAll(address(pool), true);
        for (uint256 id; id < 8; ++id) {
            _deposit(id, false);
        }
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _deposit(uint256 id, bool direct) internal {
        vm.prank(alice);
        if (direct) nft.safeTransferFrom(alice, address(pool), id, "");
        else pool.deposit(_one(id), new uint256[](0), alice);
    }

    function _pick(uint256 id) internal {
        vm.prank(alice);
        pool.redeem(_one(id), new uint256[](0), alice, address(0));
    }

    function _draw(uint256 commitId) internal returns (uint256[] memory drawn) {
        vm.recordLogs();
        vm.prank(carol);
        pool.revealRedeem(commitId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == MiyaPool.RedeemRevealed.selector) {
                assertEq(uint256(logs[i].topics[1]), commitId);
                return abi.decode(logs[i].data, (uint256[]));
            }
        }
        revert("expected settlement, not rearm");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_minedDrawsStableAcrossDepositsPicksAndNewCommits(
        bytes32 seedA,
        bytes32 seedB,
        uint8 mask,
        uint8 countA,
        uint8 countB
    ) public {
        uint256 a = bound(countA, 1, 3);
        uint256 b = bound(countB, 1, 3);
        vm.prank(alice);
        pool.commitRedeem(a, bob);
        (, uint64 firstTarget,,) = pool.commits(0);
        vm.roll(uint256(firstTarget) + 1);
        vm.setBlockhash(firstTarget, bytes32(uint256(seedA) | 1));
        _deposit(8, true); // Eligible only for the second commit.
        vm.prank(alice);
        pool.commitRedeem(b, bob);
        (, uint64 secondTarget,,) = pool.commits(1);
        vm.roll(uint256(secondTarget) + 1);
        vm.setBlockhash(secondTarget, bytes32(uint256(seedB) | 1));
        uint256 snapshot = vm.snapshotState();
        uint256[] memory baselineA = _draw(0);
        uint256[] memory baselineB = _draw(1);
        assertEq(pool.lockedEnd(), 0);
        vm.revertToStateAndDelete(snapshot);

        // Even after both seeds are known, a later reveal cannot precede the first one.
        vm.expectRevert(MiyaPool.NotNextCommit.selector);
        pool.revealRedeem(1);
        _deposit(9, mask & 1 != 0);
        _deposit(10, mask & 2 != 0);
        _deposit(11, mask & 4 != 0);
        assertFalse(pool.isLocked(9));
        assertFalse(pool.isLocked(10));
        if (mask & 8 != 0) _pick(9); // tail swap can change only positions outside pending ranges
        if (mask & 16 != 0) _pick(10);
        assertEq(_draw(0), baselineA, "first known draw changed");
        _deposit(12, true);
        if (mask & 32 != 0) _pick(11);
        if (mask & 64 != 0) {
            // A later commitment extends the lock but must not change either older commitment.
            vm.prank(alice);
            pool.commitRedeem(1, carol);
        }
        assertEq(_draw(1), baselineB, "second known draw changed");
        assertEq(nft.balanceOf(bob), a + b);
        assertEq(pool.totalSupply() + 1e18 * pool.pendingUnits(), 1e18 * pool.heldUnits());
        for (uint256 i; i < baselineA.length; ++i) {
            assertLt(baselineA[i], 8);
        }
        for (uint256 i; i < baselineB.length; ++i) {
            assertLe(baselineB[i], 8);
        }
    }
}
