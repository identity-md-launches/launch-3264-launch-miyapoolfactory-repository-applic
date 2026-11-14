// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Mock1155, MockVault, MockToken} from "../pools/MiyaPool.t.sol";

/// @dev A closed inventory of four edition ids shared by three actors. Duplicated batch ids,
///      partial balances, direct/pull deposits and fractional pool-token transfers are interleaved.
contract EditionSequenceHandler is Test {
    MiyaPool public pool;
    Mock1155 public nft;
    MockToken public imd;
    MockToken public infer;
    MockVault public vault;
    address[3] public actors;
    uint256[4] public expectedUnits;
    uint256 public depositedUnits;
    uint256 public redeemedUnits;
    uint256 public violations;
    mapping(address => uint256) public feesBy;

    constructor() {
        imd = new MockToken("IMD");
        infer = new MockToken("INFER");
        vault = new MockVault(address(imd), address(infer));
        nft = new Mock1155();
        pool = MiyaPool(new MiyaPoolFactory(address(vault)).createPool(address(nft), 0, 3500e18));
        for (uint256 a; a < 3; ++a) {
            actors[a] = makeAddr(string.concat("edition actor ", vm.toString(a)));
            infer.mint(actors[a], 1e30);
            for (uint256 id; id < 4; ++id) {
                nft.mint(actors[a], id, 100);
            }
            vm.startPrank(actors[a]);
            nft.setApprovalForAll(address(pool), true);
            infer.approve(address(pool), type(uint256).max);
            vm.stopPrank();
            deposit(a, a, 0, 20, 7, a % 2 == 0);
        }
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function deposit(
        uint256 actorSeed,
        uint256 toSeed,
        uint256 idSeed,
        uint256 amountSeed,
        uint256 splitSeed,
        bool direct
    ) public {
        address from = actors[actorSeed % 3];
        address to = actors[toSeed % 3];
        uint256 id = idSeed % 4;
        uint256 max = nft.balanceOf(from, id);
        if (max == 0) return;
        uint256 amount = bound(amountSeed, 1, max);
        uint256 split = bound(splitSeed, 0, amount);
        vm.prank(from);
        bool ok;
        if (direct) {
            try nft.safeBatchTransferFrom(
                from, address(pool), _two(id, id), _two(split, amount - split), abi.encode(to)
            ) {
                ok = true;
            } catch {
                ++violations;
            }
        } else {
            try pool.deposit(_two(id, id), _two(split, amount - split), to) {
                ok = true;
            } catch {
                ++violations;
            }
        }
        if (ok) {
            expectedUnits[id] += amount;
            depositedUnits += amount;
        }
    }

    function redeem(uint256 actorSeed, uint256 toSeed, uint256 idSeed, uint256 amountSeed, uint256 splitSeed) public {
        address from = actors[actorSeed % 3];
        address to = actors[toSeed % 3];
        uint256 id = idSeed % 4;
        uint256 max = expectedUnits[id];
        if (max > pool.balanceOf(from) / 1e18) max = pool.balanceOf(from) / 1e18;
        if (max == 0) return;
        uint256 amount = bound(amountSeed, 1, max);
        uint256[] memory ids;
        uint256[] memory amounts;
        if (amount == 1) {
            ids = new uint256[](1);
            ids[0] = id;
            amounts = new uint256[](1);
            amounts[0] = 1;
        } else {
            uint256 split = bound(splitSeed, 1, amount - 1);
            ids = _two(id, id);
            amounts = _two(split, amount - split);
        }
        vm.prank(from);
        try pool.redeem(ids, amounts, to, address(infer)) {
            expectedUnits[id] -= amount;
            redeemedUnits += amount;
            feesBy[from] += amount * 3500e18;
        } catch {
            ++violations;
        }
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
    }

    function closeAll() external {
        for (uint256 a = 1; a < 3; ++a) {
            uint256 amount = pool.balanceOf(actors[a]);
            vm.prank(actors[a]);
            pool.transfer(actors[0], amount);
        }
        for (uint256 id; id < 4; ++id) {
            if (expectedUnits[id] != 0) redeem(0, 0, id, expectedUnits[id], 1);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract MiyaPool1155InvariantTest is Test {
    EditionSequenceHandler handler;

    function setUp() public {
        vm.chainId(4663);
        handler = new EditionSequenceHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.transferShares.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_everyEditionAndFeeIsConserved() public view {
        MiyaPool pool = handler.pool();
        assertEq(handler.violations(), 0);
        assertFalse(pool.randomEnabled());
        assertEq(pool.pendingUnits(), 0);
        uint256 held;
        uint256 distinct;
        for (uint256 id; id < 4; ++id) {
            uint256 expected = handler.expectedUnits(id);
            assertEq(pool.unitsOf(id), expected);
            assertEq(handler.nft().balanceOf(address(pool), id), expected);
            assertEq(pool.isHeld(id), expected != 0);
            uint256 acrossActors;
            for (uint256 a; a < 3; ++a) {
                acrossActors += handler.nft().balanceOf(handler.actors(a), id);
            }
            assertEq(acrossActors + expected, 300, "closed NFT inventory");
            held += expected;
            if (expected != 0) ++distinct;
        }
        assertEq(pool.heldUnits(), held);
        assertEq(pool.heldIdsCount(), distinct);
        assertEq(held, handler.depositedUnits() - handler.redeemedUnits());
        assertEq(pool.totalSupply(), held * 1e18);
        uint256 shares;
        uint256 fees;
        for (uint256 a; a < 3; ++a) {
            address actor = handler.actors(a);
            shares += pool.balanceOf(actor);
            uint256 paid = handler.feesBy(actor);
            fees += paid;
            assertEq(handler.vault().pendingOf(actor, address(handler.infer())), paid);
            assertEq(handler.infer().balanceOf(actor) + paid, 1e30);
        }
        assertEq(shares, pool.totalSupply());
        assertEq(handler.infer().balanceOf(address(handler.vault())), fees);
        assertEq(handler.vault().totalOf(address(handler.infer())), fees);
        assertEq(handler.infer().balanceOf(address(pool)), 0);
        assertEq(handler.infer().allowance(address(pool), address(handler.vault())), 0);
    }

    function afterInvariant() public {
        handler.closeAll();
        assertEq(handler.violations(), 0);
        assertEq(handler.pool().totalSupply(), 0);
        assertEq(handler.pool().heldUnits(), 0);
        for (uint256 id; id < 4; ++id) {
            assertEq(handler.nft().balanceOf(address(handler.pool()), id), 0);
        }
    }
}
