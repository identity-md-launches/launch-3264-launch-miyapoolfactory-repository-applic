// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WalletGas} from "../helpers/WalletGas.sol";
import {HistoryFixture} from "../helpers/HistoryFixture.sol";
import {MiyaPool} from "src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "src/pools/MiyaPoolFactory.sol";
import {Mock721, Mock1155, Blocking721, MockVault, MockToken, RefusingNotify721, GasBurner} from "./MiyaPool.t.sol";

/// @notice Uses the supplied helper unchanged: every probe compares return data AND logs at minimum
///         successful gas with gas to spare. It never asserts that work being skipped is acceptable.
contract MiyaPoolWalletGasTest is WalletGas {
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    address alice = makeAddr("wallet depositor");
    address bob = makeAddr("wallet recipient");
    address revealer = makeAddr("permissionless revealer");
    MiyaPoolFactory factory;

    function setUp() public {
        vm.chainId(1);
        vm.roll(10_000);
        MockVault vault = new MockVault(address(new MockToken("IMD")), address(new MockToken("INFER")));
        factory = new MiyaPoolFactory(address(vault));
    }

    function _committed(Mock721 nft, uint256 count, address recipient) internal returns (MiyaPool pool) {
        pool = MiyaPool(factory.createPool(address(nft), 0, 0));
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            nft.mint(alice, i);
            ids[i] = i;
        }
        vm.startPrank(alice);
        nft.setApprovalForAll(address(pool), true);
        pool.deposit(ids, new uint256[](0), alice);
        pool.commitRedeem(count, recipient);
        vm.stopPrank();
        (, uint64 target,,) = pool.commits(0);
        vm.roll(uint256(target) + 1);
        vm.setBlockhash(target, keccak256("wallet gas seed"));
    }

    function test_walletGas_factoryERC721WithFees() public {
        Mock721 nft = new Mock721();
        assertSameAtWalletGas(
            alice, address(factory), abi.encodeCall(factory.createPool, (address(nft), 1e18, 3500e18))
        );
        assertEq(factory.allPoolsLength(), 0, "helper restores deployment state");
    }

    function test_walletGas_factoryERC1155Free() public {
        Mock1155 nft = new Mock1155();
        assertSameAtWalletGas(alice, address(factory), abi.encodeCall(factory.createPool, (address(nft), 0, 0)));
    }

    function test_walletGas_revealOne() public {
        MiyaPool pool = _committed(new Mock721(), 1, bob);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
        assertEq(pool.pendingUnits(), 1, "helper restores commit");
    }

    function test_walletGas_revealFifty() public {
        MiyaPool pool = _committed(new Mock721(), 50, bob);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
    }

    function test_walletGas_refusedTransfersEscrowAllFifty() public {
        Blocking721 nft = new Blocking721();
        nft.setBlocked(bob);
        MiyaPool pool = _committed(nft, 50, bob);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
    }

    function test_walletGas_fiftyTransfersConsumeTheirEntireAllowance() public {
        RefusingNotify721 nft = new RefusingNotify721();
        address burner = address(new GasBurner());
        nft.setNotified(burner);
        MiyaPool pool = _committed(nft, 50, burner);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
    }

    function test_walletGas_expiredCommitRearms() public {
        MiyaPool pool = _committed(new Mock721(), 1, bob);
        (, uint64 target,,) = pool.commits(0);
        vm.roll(uint256(target) + 8192);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
    }

    function test_walletGas_revealUsesHistoryAtLastValidBlock() public {
        MiyaPool pool = _committed(new Mock721(), 1, bob);
        (, uint64 target,,) = pool.commits(0);
        vm.etch(HISTORY, address(new HistoryFixture()).code);
        HistoryFixture(HISTORY).set(target, keccak256("recorded history"));
        vm.roll(uint256(target) + 8191);
        assertSameAtWalletGas(revealer, address(pool), abi.encodeCall(pool.revealRedeem, (0)));
    }
}
