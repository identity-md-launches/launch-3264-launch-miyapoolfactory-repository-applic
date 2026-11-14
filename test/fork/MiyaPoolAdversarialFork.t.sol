// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WalletGas} from "../helpers/WalletGas.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Mock721, Mock1155} from "../pools/MiyaPool.t.sol";
import {IVaultCfg, IVaultView, IERC20Like} from "./MiyaPoolV2Fork.t.sol";

/// @notice Local NFT fixtures exercise both pool kinds against the actual vault, registry and fee
///         token bytecode. The existing fork suite separately deposits NFTs from the live collection.
contract MiyaPoolAdversarialForkTest is WalletGas {
    uint256 constant FORK_BLOCK = 26_409_294;
    address constant VAULT = 0x34bE8C25C7922B3052D1955b8E63fB97F778AA08;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    address alice = makeAddr("fork depositor");
    address picker = makeAddr("fork picker");
    address recipient = makeAddr("fork NFT recipient");
    MiyaPoolFactory factory;
    Mock721 nft;
    Mock1155 editions;
    MiyaPool pool721;
    MiyaPool pool1155;
    uint256 imdFee;
    uint256 inferFee;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertGt(VAULT.code.length, 0);
        assertGt(IMD.code.length, 0);
        assertGt(INFER.code.length, 0);
        factory = new MiyaPoolFactory(VAULT);
        assertEq(factory.imd(), IMD);
        assertEq(factory.infer(), INFER);
        address config = IVaultCfg(VAULT).config();
        imdFee = IVaultCfg(config).minContribution(IMD);
        inferFee = IVaultCfg(config).minContribution(INFER);
        assertEq(imdFee, 1e18);
        assertEq(inferFee, 3500e18);
        nft = new Mock721();
        editions = new Mock1155();
        pool721 = MiyaPool(factory.createPool(address(nft), imdFee, inferFee));
        pool1155 = MiyaPool(factory.createPool(address(editions), imdFee, inferFee));
        nft.mint(alice, 0);
        nft.mint(alice, 1);
        editions.mint(alice, 0, 10);
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(pool721), 0, abi.encode(picker));
        nft.safeTransferFrom(alice, address(pool721), 1, abi.encode(picker));
        editions.safeTransferFrom(alice, address(pool1155), 0, 10, abi.encode(picker));
        vm.stopPrank();
        deal(IMD, picker, 12 * imdFee);
        deal(INFER, picker, 12 * inferFee);
        vm.startPrank(picker);
        IERC20Like(IMD).approve(address(pool721), 2 * imdFee);
        IERC20Like(INFER).approve(address(pool721), 2 * inferFee);
        IERC20Like(IMD).approve(address(pool1155), 10 * imdFee);
        IERC20Like(INFER).approve(address(pool1155), 10 * inferFee);
        vm.stopPrank();
    }

    function _one(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = n;
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function test_fork_1155RepeatedIdsPayBothLiveFeesPerUnitToPicker() public {
        IVaultView v = IVaultView(VAULT);
        uint256 imdBefore = IERC20Like(IMD).balanceOf(VAULT);
        uint256 inferBefore = IERC20Like(INFER).balanceOf(VAULT);
        uint256 imdPending = v.pendingByToken(IMD);
        uint256 inferPending = v.pendingByToken(INFER);
        vm.startPrank(picker);
        pool1155.redeem(_two(0, 0), _two(2, 3), recipient, IMD);
        pool1155.redeem(_one(0), _one(5), recipient, INFER);
        vm.stopPrank();
        assertEq(editions.balanceOf(recipient, 0), 10);
        assertEq(editions.balanceOf(address(pool1155), 0), 0);
        assertEq(pool1155.totalSupply(), 0);
        assertEq(pool1155.heldUnits(), 0);
        assertEq(v.pendingOf(picker, IMD), 5 * imdFee);
        assertEq(v.pendingOf(picker, INFER), 5 * inferFee);
        assertEq(v.pendingOf(recipient, IMD) + v.pendingOf(alice, IMD), 0);
        assertEq(v.pendingByToken(IMD) - imdPending, 5 * imdFee);
        assertEq(v.pendingByToken(INFER) - inferPending, 5 * inferFee);
        assertEq(IERC20Like(IMD).balanceOf(VAULT) - imdBefore, 5 * imdFee);
        assertEq(IERC20Like(INFER).balanceOf(VAULT) - inferBefore, 5 * inferFee);
        assertEq(IERC20Like(IMD).balanceOf(picker), 7 * imdFee);
        assertEq(IERC20Like(INFER).balanceOf(picker), 7 * inferFee);
        assertEq(IERC20Like(IMD).balanceOf(address(pool1155)), 0);
        assertEq(IERC20Like(INFER).balanceOf(address(pool1155)), 0);
        assertEq(IERC20Like(IMD).allowance(address(pool1155), VAULT), 0);
        assertEq(IERC20Like(INFER).allowance(address(pool1155), VAULT), 0);
    }

    function test_fork_shortLiveFeeAllowanceRollsBackBatch() public {
        vm.startPrank(picker);
        IERC20Like(IMD).approve(address(pool721), 2 * imdFee - 1);
        vm.expectRevert();
        pool721.redeem(_two(0, 1), new uint256[](0), recipient, IMD);
        vm.stopPrank();
        assertEq(nft.balanceOf(address(pool721)), 2);
        assertEq(pool721.totalSupply(), 2e18);
        assertEq(pool721.balanceOf(picker), 2e18);
        assertEq(IERC20Like(IMD).balanceOf(picker), 12 * imdFee);
        assertEq(IERC20Like(IMD).allowance(picker, address(pool721)), 2 * imdFee - 1);
        assertEq(IVaultView(VAULT).pendingOf(picker, IMD), 0);
        assertEq(pool721.queuePositionOf(0), 0);
        assertEq(pool721.queuePositionOf(1), 1);
    }

    function test_fork_refusedNFTReceiverRollsBackLiveContribution() public {
        uint256 vaultBefore = IERC20Like(INFER).balanceOf(VAULT);
        uint256 pendingBefore = IVaultView(VAULT).pendingByToken(INFER);
        vm.prank(picker);
        vm.expectRevert();
        pool1155.redeem(_one(0), _one(10), address(factory), INFER);
        assertEq(pool1155.totalSupply(), 10e18);
        assertEq(editions.balanceOf(address(pool1155), 0), 10);
        assertEq(IERC20Like(INFER).balanceOf(picker), 12 * inferFee);
        assertEq(IERC20Like(INFER).balanceOf(VAULT), vaultBefore);
        assertEq(IVaultView(VAULT).pendingByToken(INFER), pendingBefore);
        assertEq(IVaultView(VAULT).pendingOf(picker, INFER), 0);
        assertEq(IERC20Like(INFER).allowance(picker, address(pool1155)), 10 * inferFee);
        assertEq(IERC20Like(INFER).allowance(address(pool1155), VAULT), 0);
    }

    function test_fork_feeBelowLiveInferMinimumLeavesNoPoolAndCanRetry() public {
        Mock1155 other = new Mock1155();
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.FeeBelowVaultMinimum.selector, INFER, inferFee));
        factory.createPool(address(other), 0, inferFee - 1);
        assertEq(factory.poolOf(address(other)), address(0));
        assertEq(factory.allPoolsLength(), 2);
        MiyaPool created = MiyaPool(factory.createPool(address(other), 0, inferFee));
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.FeeTokenNotOffered.selector, IMD));
        created.pickFee(IMD, 1);
        assertEq(created.pickFee(INFER, 2), 2 * inferFee);
        assertEq(factory.allPoolsLength(), 3);
    }

    function test_fork_walletGasLiveImdPick() public {
        assertSameAtWalletGas(
            picker, address(pool721), abi.encodeCall(pool721.redeem, (_one(0), new uint256[](0), recipient, IMD))
        );
    }

    function test_fork_walletGasLiveInferBatchPick() public {
        assertSameAtWalletGas(
            picker, address(pool1155), abi.encodeCall(pool1155.redeem, (_one(0), _one(10), recipient, INFER))
        );
    }

    function test_fork_actualHistoryContractAnswersAtBothSupportedEdges() public view {
        assertGt(HISTORY.code.length, 0);
        (bool ok257, bytes memory hash257) = HISTORY.staticcall(abi.encode(FORK_BLOCK - 257));
        (bool ok8191, bytes memory hash8191) = HISTORY.staticcall(abi.encode(FORK_BLOCK - 8191));
        (bool ok8192,) = HISTORY.staticcall(abi.encode(FORK_BLOCK - 8192));
        assertTrue(ok257 && ok8191);
        assertEq(hash257.length, 32);
        assertEq(hash8191.length, 32);
        assertNotEq(abi.decode(hash257, (bytes32)), bytes32(0));
        assertNotEq(abi.decode(hash8191, (bytes32)), bytes32(0));
        assertFalse(ok8192, "expired history must not be served");
    }
}
