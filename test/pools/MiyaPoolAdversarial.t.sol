// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Mock721, Mock1155, MockToken, MockVault, Blocking721} from "./MiyaPool.t.sol";
import {HistoryFixture} from "../helpers/HistoryFixture.sol";

contract RejectOne721 is Mock721 {
    uint256 public refusedId;
    address public refusedTo;

    function refuse(uint256 id, address to) external {
        refusedId = id;
        refusedTo = to;
    }

    function _beforeTokenTransfer(address, address to, uint256 id) internal view override {
        require(id != refusedId || to != refusedTo, "id refused");
    }
}

contract Returning1155Receiver {
    MiyaPool public pool;
    Mock1155 public nft;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    uint256 public returnUnits;

    constructor(MiyaPool p, Mock1155 n, uint256 units) {
        pool = p;
        nft = n;
        returnUnits = units;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata ids, uint256[] calldata, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == address(nft));
        bytes memory err;
        (reentrySucceeded, err) = address(pool).call(abi.encodeCall(pool.commitRedeem, (1, address(this))));
        reentryError = bytes4(err);
        if (returnUnits != 0) nft.safeTransferFrom(address(this), address(pool), ids[0], returnUnits, "");
        return this.onERC1155BatchReceived.selector;
    }
}

/// @dev All responses are deliberately invalid ERC-165 implementations, never deployed application dependencies.
contract Odd165 {
    uint256 immutable mode;

    constructor(uint256 mode_) {
        mode = mode_;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        if (mode == 0) {
            assembly { return(0, 0) }
        }
        if (mode == 1) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0xd9b67a26;
        return id == 0x01ffc9a7;
    }
}

contract MiyaPoolAdversarialTest is Test {
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 constant UNIT = 1e18;
    address alice = makeAddr("adversarial alice");
    address bob = makeAddr("adversarial bob");
    address operator = makeAddr("adversarial operator");
    MockToken imd;
    MockToken infer;
    MockVault vault;
    MiyaPoolFactory factory;

    function setUp() public {
        vm.chainId(1);
        vm.roll(10000);
        imd = new MockToken("IMD");
        infer = new MockToken("INFER");
        vault = new MockVault(address(imd), address(infer));
        factory = new MiyaPoolFactory(address(vault));
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _deposit721(Mock721 nft, MiyaPool p, uint256 count) internal {
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            nft.mint(alice, i);
            ids[i] = i;
        }
        vm.startPrank(alice);
        nft.setApprovalForAll(address(p), true);
        p.deposit(ids, new uint256[](0), alice);
        vm.stopPrank();
    }

    function _fundPick(MiyaPool p, uint256 amount) internal {
        imd.mint(alice, amount);
        vm.prank(alice);
        imd.approve(address(p), amount);
    }

    function _ready(MiyaPool p, uint256 c) internal {
        (, uint64 target,,) = p.commits(c);
        if (vm.getBlockNumber() <= target) vm.roll(uint256(target) + 1);
        vm.setBlockhash(target, keccak256(abi.encode("adversarial", c)));
    }

    function _backed(MiyaPool p) internal view {
        assertEq(p.totalSupply() + UNIT * p.pendingUnits(), UNIT * p.heldUnits());
        assertEq(imd.balanceOf(address(p)), 0);
        assertEq(infer.balanceOf(address(p)), 0);
    }

    function test_direct721OperatorCannotStealDefaultCredit() public {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        nft.mint(alice, 0);
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);
        vm.prank(operator);
        nft.safeTransferFrom(alice, address(p), 0, hex"1234");
        assertEq(p.balanceOf(alice), UNIT);
        assertEq(p.balanceOf(operator), 0);
        assertEq(nft.ownerOf(0), address(p));
        _backed(p);
    }

    function test_malformedRecipientWordRollsBackTransferAndMint() public {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        nft.mint(alice, 0);
        vm.prank(alice);
        vm.expectRevert();
        nft.safeTransferFrom(alice, address(p), 0, abi.encode(type(uint256).max));
        assertEq(nft.ownerOf(0), alice);
        assertEq(p.heldUnits(), 0);
        assertEq(p.totalSupply(), 0);
        (uint256 head, uint256 tail) = p.queueBounds();
        assertEq(head + tail, 0);
    }

    function test_direct721ExplicitRecipientAndZeroFallback() public {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        nft.mint(alice, 0);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(p), 0, abi.encode(bob));
        nft.safeTransferFrom(alice, address(p), 1, abi.encode(address(0)));
        vm.stopPrank();
        assertEq(p.balanceOf(bob), UNIT);
        assertEq(p.balanceOf(alice), UNIT);
        _backed(p);
    }

    function test_lateNFTFailureRollsBackBothTransfersBurnFeeAndVaultCredit() public {
        RejectOne721 nft = new RejectOne721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), UNIT, 0));
        _deposit721(nft, p, 2);
        _fundPick(p, 2 * UNIT);
        nft.refuse(1, bob);
        vm.prank(alice);
        vm.expectRevert("id refused");
        p.redeem(_two(0, 1), new uint256[](0), bob, address(imd));
        assertEq(nft.ownerOf(0), address(p));
        assertEq(nft.ownerOf(1), address(p));
        assertEq(p.balanceOf(alice), 2 * UNIT);
        assertEq(imd.balanceOf(alice), 2 * UNIT);
        assertEq(imd.allowance(alice, address(p)), 2 * UNIT);
        assertEq(imd.allowance(address(p), address(vault)), 0);
        assertEq(vault.pendingOf(alice, address(imd)), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(p.queuePositionOf(0), 0);
        assertEq(p.queuePositionOf(1), 1);
        _backed(p);
        nft.refuse(99, bob);
        vm.prank(alice);
        p.redeem(_two(0, 1), new uint256[](0), bob, address(imd));
        assertEq(nft.balanceOf(bob), 2);
        assertEq(vault.pendingOf(alice, address(imd)), 2 * UNIT);
    }

    function test_otherPickersFeeApprovalCannotBeSpent() public {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), UNIT, 0));
        _deposit721(nft, p, 1);
        _fundPick(p, UNIT);
        vm.prank(alice);
        p.transfer(bob, UNIT);
        vm.prank(bob);
        vm.expectRevert();
        p.redeem(_one(0), new uint256[](0), bob, address(imd));
        assertEq(imd.balanceOf(alice), UNIT);
        assertEq(p.balanceOf(bob), UNIT);
        assertEq(vault.pendingOf(alice, address(imd)), 0);
        assertEq(nft.ownerOf(0), address(p));
        _backed(p);
    }

    function test_1155ReceiverCanReturnUnitsButCannotReenterRedeem() public {
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        nft.mint(alice, 0, 5);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), 0, 5, "");
        Returning1155Receiver receiver = new Returning1155Receiver(p, nft, 2);
        vm.prank(alice);
        p.redeem(_one(0), _one(5), address(receiver), address(0));
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.reentryError(), bytes4(keccak256("Reentrancy()")));
        assertEq(nft.balanceOf(address(receiver), 0), 3);
        assertEq(nft.balanceOf(address(p), 0), 2);
        assertEq(p.balanceOf(address(receiver)), 2 * UNIT);
        assertEq(p.balanceOf(alice), 0);
        _backed(p);
    }

    function test_1155RefusingRecipientRevertsFeeAndAccounting() public {
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), UNIT, 0));
        nft.mint(alice, 0, 3);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), 0, 3, "");
        _fundPick(p, 3 * UNIT);
        vm.prank(alice);
        vm.expectRevert();
        p.redeem(_one(0), _one(3), address(factory), address(imd));
        assertEq(nft.balanceOf(address(p), 0), 3);
        assertEq(p.unitsOf(0), 3);
        assertEq(p.balanceOf(alice), 3 * UNIT);
        assertEq(imd.balanceOf(alice), 3 * UNIT);
        assertEq(vault.totalOf(address(imd)), 0);
        _backed(p);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_1155DuplicateIdsAndRepeatedRoundTrips(uint64 amountA, uint64 amountB, uint8 cycles) public {
        uint256 a = bound(amountA, 1, 10000);
        uint256 b = bound(amountB, 1, 10000);
        uint256 count = bound(cycles, 1, 6);
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), UNIT, 0));
        nft.mint(alice, 0, a + b);
        _fundPick(p, (a + b) * UNIT * count);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(p), true);
        for (uint256 i; i < count; ++i) {
            // Duplicated ids are legal ERC-1155 batch entries. Every occurrence counts once.
            nft.safeBatchTransferFrom(alice, address(p), _two(0, 0), _two(a, b), "");
            assertEq(p.heldIdsCount(), 1);
            assertEq(p.totalSupply(), (a + b) * UNIT);
            p.redeem(_two(0, 0), _two(b, a), alice, address(imd));
            assertEq(nft.balanceOf(alice, 0), a + b);
            assertEq(p.heldUnits(), 0);
            assertEq(p.heldIdsCount(), 0);
            assertEq(p.totalSupply(), 0);
        }
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 0);
        assertEq(vault.pendingOf(alice, address(imd)), (a + b) * UNIT * count);
        assertEq(imd.balanceOf(address(vault)), (a + b) * UNIT * count);
        _backed(p);
    }

    function test_1155ZeroEntriesCannotMintOrRedeemAnything() public {
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        nft.mint(alice, 0, 1);
        vm.prank(alice);
        nft.safeBatchTransferFrom(alice, address(p), _two(0, 1), _two(1, 0), "");
        assertEq(p.heldIdsCount(), 1);
        assertFalse(p.isHeld(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.NotHeld.selector, 0));
        p.redeem(_one(0), _one(0), bob, address(0));
        assertEq(p.totalSupply(), UNIT);
        assertEq(nft.balanceOf(address(p), 0), 1);
    }

    function test_1155LargestRepresentableDepositRoundTripsWithoutRounding() public {
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        uint256 max = type(uint256).max / UNIT;
        nft.mint(alice, 0, max);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), 0, max, "");
        assertEq(p.balanceOf(alice), max * UNIT);
        vm.prank(alice);
        p.redeem(_one(0), _one(max), alice, address(0));
        assertEq(nft.balanceOf(alice, 0), max);
        assertEq(p.totalSupply(), 0);
        assertEq(p.heldUnits(), 0);
    }

    function test_1155MultiplicationOverflowCannotLeavePartialDeposit() public {
        Mock1155 nft = new Mock1155();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        uint256 overflow = type(uint256).max / UNIT + 1;
        nft.mint(alice, 0, overflow);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        nft.safeTransferFrom(alice, address(p), 0, overflow, "");
        assertEq(nft.balanceOf(alice, 0), overflow);
        assertEq(nft.balanceOf(address(p), 0), 0);
        assertEq(p.unitsOf(0), 0);
        assertEq(p.totalSupply(), 0);
        assertEq(p.heldUnits(), 0);
    }

    function test_factoryRejectsMalformedAmbiguousAndGasBurning165Atomically() public {
        for (uint256 mode; mode < 5; ++mode) {
            Odd165 nft = new Odd165(mode);
            vm.expectRevert();
            factory.createPool(address(nft), 0, 0);
            assertEq(factory.poolOf(address(nft)), address(0));
            assertEq(factory.allPoolsLength(), 0);
        }
        Mock721 valid = new Mock721();
        address created = factory.createPool(address(valid), 0, 0);
        assertEq(factory.allPools(0), created, "hostile collection cannot poison factory");
    }

    function test_prefundingPredictionCannotSquatDeploymentOrChangeFees() public {
        Mock721 nft = new Mock721();
        address predicted = factory.predictPool(address(nft), MiyaPool.Kind.ERC721, UNIT, 3500 * UNIT);
        vm.deal(predicted, 1 wei);
        vm.prank(operator);
        address created = factory.createPool(address(nft), UNIT, 3500 * UNIT);
        assertEq(created, predicted);
        assertEq(MiyaPool(created).imdFee(), UNIT);
        assertEq(MiyaPool(created).inferFee(), 3500 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(MiyaPoolFactory.PoolExists.selector, created));
        factory.createPool(address(nft), 0, 0);
        assertEq(factory.allPoolsLength(), 1);
    }

    function test_robinhoodFeePoolHasNoRandomPathAndCanPickEntireInventory() public {
        vm.chainId(4663);
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), UNIT, 0));
        _deposit721(nft, p, 2);
        _fundPick(p, 2 * UNIT);
        assertFalse(p.randomEnabled());
        vm.startPrank(alice);
        vm.expectRevert(MiyaPool.RandomUnavailable.selector);
        p.commitRedeem(1, bob);
        assertEq(p.balanceOf(alice), 2 * UNIT);
        p.redeem(_two(0, 1), new uint256[](0), bob, address(imd));
        vm.stopPrank();
        assertEq(nft.balanceOf(bob), 2);
        assertEq(p.totalSupply(), 0);
        assertEq(vault.pendingOf(alice, address(imd)), 2 * UNIT);
        (uint256 head, uint256 tail) = p.queueBounds();
        assertEq(head + tail, 0);
        _backed(p);
    }

    function test_history256UsesBlockhashAnd257UsesHistory() public {
        _historyReveal(256, false);
        _historyReveal(257, true);
    }

    function test_history8191IsInclusive() public {
        _historyReveal(8191, true);
    }

    function _historyReveal(uint256 age, bool useHistory) internal {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        _deposit721(nft, p, 1);
        vm.prank(alice);
        p.commitRedeem(1, bob);
        (, uint64 target,,) = p.commits(0);
        vm.roll(uint256(target) + age);
        if (useHistory) {
            vm.etch(HISTORY, address(new HistoryFixture()).code);
            HistoryFixture(HISTORY).set(target, keccak256("history seed"));
        } else {
            vm.setBlockhash(target, keccak256("blockhash seed"));
        }
        p.revealRedeem(0);
        assertEq(nft.ownerOf(0), bob);
        assertEq(p.nextRevealId(), 1);
        assertEq(p.pendingUnits(), 0);
        assertEq(p.lockedEnd(), 0);
        _backed(p);
    }

    function test_expiredHistoryRearmsWithoutLosingLocksOrLiabilities() public {
        Mock721 nft = new Mock721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        _deposit721(nft, p, 3);
        vm.startPrank(alice);
        p.commitRedeem(1, bob);
        p.commitRedeem(1, bob);
        vm.stopPrank();
        (, uint64 target,, uint32 end) = p.commits(0);
        vm.etch(HISTORY, address(new HistoryFixture()).code);
        HistoryFixture(HISTORY).set(target, keccak256("expired hash must not be used"));
        vm.roll(uint256(target) + 8192);
        uint256 supply = p.totalSupply();
        p.revealRedeem(0);
        (address recipient, uint64 rearmed, uint32 amount, uint32 afterEnd) = p.commits(0);
        assertEq(recipient, bob);
        assertEq(rearmed, vm.getBlockNumber() + 1);
        assertEq(amount, 1);
        assertEq(afterEnd, end);
        assertEq(p.totalSupply(), supply);
        assertEq(p.pendingUnits(), 2);
        assertEq(p.nextRevealId(), 0);
        assertEq(p.lockedEnd(), 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(p.isLocked(i));
        }
        vm.expectRevert(MiyaPool.TooEarly.selector);
        p.revealRedeem(0);
        vm.expectRevert(MiyaPool.NotNextCommit.selector);
        p.revealRedeem(1);
        _ready(p, 0);
        p.revealRedeem(0);
        p.revealRedeem(1); // the later commit also expired; it must be re-armed in order
        assertEq(p.nextRevealId(), 1);
        _ready(p, 1);
        p.revealRedeem(1);
        assertEq(nft.balanceOf(bob), 2);
        assertEq(p.lockedEnd(), 0);
        uint256 remaining = p.heldIds(0, 1)[0];
        vm.prank(alice);
        p.redeem(_one(remaining), new uint256[](0), alice, address(0));
        assertEq(nft.balanceOf(address(p)), 0);
        _backed(p);
    }

    function test_failedEscrowClaimPreservesClaimAndSuccessfulClaimCannotRepeat() public {
        Blocking721 nft = new Blocking721();
        MiyaPool p = MiyaPool(factory.createPool(address(nft), 0, 0));
        _deposit721(nft, p, 1);
        nft.setBlocked(bob);
        vm.prank(alice);
        p.commitRedeem(1, bob);
        _ready(p, 0);
        p.revealRedeem(0);
        vm.prank(bob);
        vm.expectRevert("blocked");
        p.claimEscrowed(0, bob);
        assertEq(p.escrowedTo(0), bob);
        assertEq(nft.ownerOf(0), address(p));
        vm.prank(alice);
        vm.expectRevert(MiyaPool.NotEscrowed.selector);
        p.claimEscrowed(0, alice);
        vm.prank(bob);
        vm.expectRevert(MiyaPool.InvalidRecipient.selector);
        p.claimEscrowed(0, address(p));
        vm.prank(bob);
        p.claimEscrowed(0, alice);
        assertEq(nft.ownerOf(0), alice);
        assertEq(p.escrowedTo(0), address(0));
        vm.prank(bob);
        vm.expectRevert(MiyaPool.NotEscrowed.selector);
        p.claimEscrowed(0, bob);
        // The recovered id can re-enter normally; its old commitment cannot mint or claim it again.
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), 0, "");
        assertEq(p.balanceOf(alice), UNIT);
        vm.expectRevert(MiyaPool.UnknownCommit.selector);
        p.revealRedeem(0);
        _backed(p);
    }
}
