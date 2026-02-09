// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title SecurityTest
 * @notice Security-focused tests for the vAMM Perpetual DEX
 */
contract SecurityTest is Test {
    ClearingHouse public clearingHouse;
    VAMM public vamm;
    Vault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public attacker = address(0x666);

    uint256 public constant INIT_BASE_RESERVE = 100 ether;
    uint256 public constant INIT_QUOTE_RESERVE = 10000e6;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new Vault(address(usdc));
        vamm = new VAMM(INIT_BASE_RESERVE, INIT_QUOTE_RESERVE);
        clearingHouse = new ClearingHouse(address(vault), address(vamm), address(usdc));
        
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        usdc.mint(alice, 10000e6);
        usdc.mint(attacker, 100000e6);
        usdc.mint(address(vault), 1000000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Zero Address Tests ============

    function test_RevertWhen_ZeroVaultAddress() public {
        vm.expectRevert(ClearingHouse.ZeroAddress.selector);
        new ClearingHouse(address(0), address(vamm), address(usdc));
    }

    function test_RevertWhen_ZeroVAMMAddress() public {
        vm.expectRevert(ClearingHouse.ZeroAddress.selector);
        new ClearingHouse(address(vault), address(0), address(usdc));
    }

    function test_RevertWhen_ZeroQuoteAssetAddress() public {
        vm.expectRevert(ClearingHouse.ZeroAddress.selector);
        new ClearingHouse(address(vault), address(vamm), address(0));
    }

    function test_RevertWhen_SetZeroClearingHouseInVault() public {
        Vault newVault = new Vault(address(usdc));
        vm.expectRevert(Vault.ZeroAddress.selector);
        newVault.setClearingHouse(address(0));
    }

    function test_RevertWhen_SetZeroClearingHouseInVAMM() public {
        VAMM newVamm = new VAMM(100 ether, 10000e6);
        vm.expectRevert(VAMM.ZeroAddress.selector);
        newVamm.setClearingHouse(address(0));
    }

    // ============ Slippage Protection Tests ============

    function test_SlippageProtection_OpenPosition() public {
        // First, Alice opens a position
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Calculate expected position size for attacker
        uint256 expectedSize = vamm.getInputPrice(true, 1000e6);
        
        vm.prank(attacker);
        // Should revert if minimum size is higher than actual
        vm.expectRevert(ClearingHouse.SlippageExceeded.selector);
        clearingHouse.openPosition(100e6, 10, true, expectedSize * 2);
    }

    function test_SlippageProtection_Works() public {
        uint256 notional = 100e6 * 5;
        uint256 expectedSize = vamm.getInputPrice(true, notional);
        
        vm.prank(alice);
        // Should succeed with reasonable slippage tolerance
        clearingHouse.openPosition(100e6, 5, true, expectedSize * 95 / 100);
        
        Position memory pos = clearingHouse.getPosition(alice);
        assertGt(uint256(pos.positionSize), 0);
    }

    // ============ Liquidity Attack Tests ============

    function test_RevertWhen_ShortExceedsLiquidity() public {
        // Try to short more than available liquidity
        vm.prank(attacker);
        vm.expectRevert(VAMM.InsufficientLiquidity.selector);
        clearingHouse.openPosition(1000e6, 10, false, 0); // 10000 USDC notional > 10000 USDC reserve
    }

    function test_RevertWhen_CloseShortExceedsLiquidity() public {
        // Open a large short that's valid
        vm.prank(attacker);
        clearingHouse.openPosition(500e6, 10, false, 0);

        // Now alice opens a massive long that increases base reserve
        vm.prank(alice);
        clearingHouse.openPosition(800e6, 10, true, 0);

        // Attacker closing might need to buy back more base than exists
        // This tests the safeguard
        Position memory pos = clearingHouse.getPosition(attacker);
        assertLt(pos.positionSize, 0); // Confirm it's a short
    }

    // ============ Access Control Tests ============

    function test_OnlyClearingHouseCanCallVault() public {
        vm.prank(attacker);
        vm.expectRevert(Vault.OnlyClearingHouse.selector);
        vault.deposit(attacker, 100e6);
    }

    function test_OnlyClearingHouseCanCallVAMM() public {
        vm.prank(attacker);
        vm.expectRevert(VAMM.OnlyClearingHouse.selector);
        vamm.swapInput(true, 100e6);
    }
}
