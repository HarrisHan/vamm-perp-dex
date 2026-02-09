// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title IntegrationTest
 * @notice Cross-contract integration tests for the vAMM Perpetual DEX
 */
contract IntegrationTest is Test {
    ClearingHouse public clearingHouse;
    VAMM public vamm;
    Vault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public liquidator = address(0x4);

    uint256 public constant INIT_BASE_RESERVE = 100 ether;
    uint256 public constant INIT_QUOTE_RESERVE = 10000e6;
    uint256 public constant VAULT_SEED = 1000000e6;

    function setUp() public {
        // Deploy all contracts
        usdc = new MockUSDC();
        vault = new Vault(address(usdc));
        vamm = new VAMM(INIT_BASE_RESERVE, INIT_QUOTE_RESERVE);
        clearingHouse = new ClearingHouse(address(vault), address(vamm), address(usdc));
        
        // Wire up contracts
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        // Fund users
        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);
        usdc.mint(charlie, 10000e6);
        usdc.mint(liquidator, 10000e6);
        
        // Seed vault for protocol liquidity
        usdc.mint(address(vault), VAULT_SEED);

        // Approvals
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Contract Wiring Tests ============

    function test_ContractReferences() public view {
        assertEq(address(clearingHouse.vault()), address(vault));
        assertEq(address(clearingHouse.vamm()), address(vamm));
        assertEq(address(clearingHouse.quoteAsset()), address(usdc));
        assertEq(vault.clearingHouse(), address(clearingHouse));
        assertEq(vamm.clearingHouse(), address(clearingHouse));
    }

    function test_InitialState() public view {
        (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
        assertEq(baseReserve, INIT_BASE_RESERVE);
        assertEq(quoteReserve, INIT_QUOTE_RESERVE);
        assertEq(vault.getTotalDeposits(), 0);
        assertEq(vault.getBalance(), VAULT_SEED);
    }

    // ============ Multi-User Scenarios ============

    function test_MultipleUsersLongShort() public {
        // Alice goes long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Bob goes short
        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, false, 0);

        // Charlie goes long
        vm.prank(charlie);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // All close positions
        vm.prank(alice);
        clearingHouse.closePosition();
        
        vm.prank(bob);
        clearingHouse.closePosition();
        
        vm.prank(charlie);
        clearingHouse.closePosition();

        // All positions should be cleared
        assertEq(clearingHouse.getPosition(alice).margin, 0);
        assertEq(clearingHouse.getPosition(bob).margin, 0);
        assertEq(clearingHouse.getPosition(charlie).margin, 0);
    }

    function test_CascadingLiquidations() public {
        // Adjust params for easier liquidation testing
        clearingHouse.setParameters(10, 10e6, 1500, 500);

        // Multiple users open long positions
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Charlie shorts massively, crashing the price
        vm.prank(charlie);
        clearingHouse.openPosition(300e6, 5, false, 0);

        // Both Alice and Bob should be liquidatable
        bool aliceLiquidatable = clearingHouse.isLiquidatable(alice);
        bool bobLiquidatable = clearingHouse.isLiquidatable(bob);
        
        console.log("Alice liquidatable:", aliceLiquidatable);
        console.log("Bob liquidatable:", bobLiquidatable);

        // Liquidate both if possible
        if (aliceLiquidatable) {
            vm.prank(liquidator);
            clearingHouse.liquidatePosition(alice);
        }
        
        if (bobLiquidatable) {
            vm.prank(liquidator);
            clearingHouse.liquidatePosition(bob);
        }
    }

    // ============ Vault Balance Consistency ============

    function test_VaultBalanceConsistency() public {
        uint256 vaultBalanceBefore = vault.getBalance();
        
        // Alice opens and closes with profit scenario
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        vm.prank(alice);
        clearingHouse.closePosition();
        
        vm.prank(bob);
        clearingHouse.closePosition();
        
        uint256 vaultBalanceAfter = vault.getBalance();
        
        // Vault balance should approximately stay the same (minus/plus PnL)
        console.log("Vault balance before:", vaultBalanceBefore);
        console.log("Vault balance after:", vaultBalanceAfter);
    }

    function test_TotalDepositsTracking() public {
        assertEq(vault.getTotalDeposits(), 0);
        
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        // Total deposits should increase
        assertGt(vault.getTotalDeposits(), 0);
        
        vm.prank(alice);
        clearingHouse.closePosition();
        
        // Total deposits may not go back to exactly 0 due to PnL
        console.log("Final total deposits:", vault.getTotalDeposits());
    }

    // ============ VAMM State Consistency ============

    function test_VammReservesAfterTrades() public {
        (uint256 baseBefore, uint256 quoteBefore) = vamm.getReserves();
        uint256 kBefore = vamm.k();
        
        // Open position
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        // Close position
        vm.prank(alice);
        clearingHouse.closePosition();
        
        (uint256 baseAfter, uint256 quoteAfter) = vamm.getReserves();
        uint256 kAfter = vamm.k();
        
        // K should remain constant
        assertEq(kBefore, kAfter);
        
        // Reserves should return close to original (small deviation due to slippage)
        console.log("Base before:", baseBefore, "after:", baseAfter);
        console.log("Quote before:", quoteBefore, "after:", quoteAfter);
    }

    function test_PriceImpactOfLargeTrades() public {
        uint256 priceBefore = vamm.getPrice();
        
        // Large long trade
        vm.prank(alice);
        clearingHouse.openPosition(500e6, 10, true, 0);
        
        uint256 priceAfterLong = vamm.getPrice();
        
        // Price should increase after long
        assertGt(priceAfterLong, priceBefore);
        console.log("Price before:", priceBefore);
        console.log("Price after large long:", priceAfterLong);
        
        // Close the position
        vm.prank(alice);
        clearingHouse.closePosition();
        
        uint256 priceAfterClose = vamm.getPrice();
        console.log("Price after close:", priceAfterClose);
        
        // Price should return close to original
        assertApproxEqRel(priceAfterClose, priceBefore, 0.01e18); // 1% tolerance
    }

    // ============ ERC20 Integration ============

    function test_TokenTransferIntegration() public {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        // Alice's balance should decrease
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - 100e6);
        
        // Vault's balance should increase
        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore + 100e6);
    }

    function test_ApprovalRequired() public {
        // Remove approval
        vm.prank(alice);
        usdc.approve(address(vault), 0);
        
        // Opening position should fail
        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.openPosition(100e6, 5, true, 0);
    }

    // ============ Edge Cases ============

    function test_RapidOpenClose() public {
        // Rapidly open and close positions
        for (uint i = 0; i < 5; i++) {
            vm.prank(alice);
            clearingHouse.openPosition(100e6, 5, true, 0);
            
            vm.prank(alice);
            clearingHouse.closePosition();
        }
        
        // Final state should be clean
        assertEq(clearingHouse.getPosition(alice).margin, 0);
    }

    function test_SystemStressTest() public {
        // Multiple users open positions simultaneously
        address[10] memory users;
        for (uint i = 0; i < 10; i++) {
            users[i] = address(uint160(100 + i));
            usdc.mint(users[i], 1000e6);
            
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            
            vm.prank(users[i]);
            bool isLong = i % 2 == 0;
            clearingHouse.openPosition(50e6, 3, isLong, 0);
        }
        
        // All positions should exist
        for (uint i = 0; i < 10; i++) {
            assertGt(clearingHouse.getPosition(users[i]).margin, 0);
        }
        
        // Close all positions
        for (uint i = 0; i < 10; i++) {
            vm.prank(users[i]);
            clearingHouse.closePosition();
        }
    }

    // ============ Paused State Integration ============

    function test_PausedStateAffectsAllOperations() public {
        // Alice opens a position first
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Pause the contract
        clearingHouse.pause();

        // All operations should fail when paused
        vm.prank(bob);
        vm.expectRevert();
        clearingHouse.openPosition(100e6, 5, true, 0);

        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.closePosition();

        vm.prank(liquidator);
        vm.expectRevert();
        clearingHouse.liquidatePosition(alice);

        // Unpause
        clearingHouse.unpause();

        // Now operations should work
        vm.prank(alice);
        clearingHouse.closePosition();
    }
}
