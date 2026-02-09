// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title BusinessLogicTest
 * @notice Business logic focused tests for the vAMM Perpetual DEX
 */
contract BusinessLogicTest is Test {
    ClearingHouse public clearingHouse;
    VAMM public vamm;
    Vault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public liquidator = address(0x3);

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
        usdc.mint(bob, 10000e6);
        usdc.mint(liquidator, 10000e6);
        usdc.mint(address(vault), 1000000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Self-Liquidation Prevention Tests ============

    function test_RevertWhen_SelfLiquidation() public {
        // Alice opens a leveraged long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Bob moves price down
        vm.prank(bob);
        clearingHouse.openPosition(300e6, 5, false, 0);

        // Confirm Alice is liquidatable
        assertTrue(clearingHouse.isLiquidatable(alice));

        // Alice tries to liquidate herself - should fail
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.CannotSelfLiquidate.selector);
        clearingHouse.liquidatePosition(alice);
    }

    // ============ Protocol Fee Tests ============

    function test_ProtocolFeesCollected() public {
        // Lower the maintenance margin ratio to make it easier to be liquidatable with remaining margin
        clearingHouse.setParameters(10, 10e6, 1500, 500); // 15% maintenance margin
        
        // Alice opens a position with 5x leverage
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Bob shorts mildly
        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, false, 0);

        int256 pnl = clearingHouse.getUnrealizedPnl(alice);
        console.log("Alice unrealized PnL:");
        console.logInt(pnl);
        
        uint256 marginRatio = clearingHouse.getMarginRatio(alice);
        console.log("Alice margin ratio:", marginRatio);
        
        // Confirm Alice is liquidatable
        assertTrue(clearingHouse.isLiquidatable(alice), "Alice should be liquidatable");
        
        // Confirm Alice has remaining margin
        assertGt(int256(100e6) + pnl, 0, "Alice should have remaining margin");

        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);

        uint256 fees = clearingHouse.protocolFees();
        assertGt(fees, 0, "Protocol fees should be > 0");
        console.log("Protocol fees collected:", fees);
    }

    function test_WithdrawProtocolFees() public {
        // Setup: adjust params for easier testing
        clearingHouse.setParameters(10, 10e6, 1500, 500);
        
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, false, 0);

        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);

        uint256 fees = clearingHouse.protocolFees();
        assertGt(fees, 0, "Should have collected fees");
        
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        // Owner withdraws fees
        clearingHouse.withdrawProtocolFees(owner, fees);

        assertEq(clearingHouse.protocolFees(), 0);
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + fees);
    }

    function test_RevertWhen_WithdrawExcessiveFees() public {
        vm.expectRevert("Insufficient protocol fees");
        clearingHouse.withdrawProtocolFees(owner, 1000e6);
    }

    function test_RevertWhen_WithdrawToZeroAddress() public {
        vm.expectRevert(ClearingHouse.ZeroAddress.selector);
        clearingHouse.withdrawProtocolFees(address(0), 0);
    }

    // ============ Minimum Position Size Tests ============

    function test_RevertWhen_PositionTooSmall() public {
        // Set a high minimum position size
        clearingHouse.setMinPositionSize(10 ether);

        // Try to open a tiny position
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.PositionSizeTooSmall.selector);
        clearingHouse.openPosition(10e6, 1, true, 0); // Would result in ~0.1 ETH
    }

    function test_MinPositionSize_CanBeUpdated() public {
        clearingHouse.setMinPositionSize(5 ether);
        assertEq(clearingHouse.minPositionSize(), 5 ether);
    }

    // ============ Edge Case Tests ============

    function test_LiquidationRewardDistribution() public {
        // Setup params for easier testing
        clearingHouse.setParameters(10, 10e6, 1500, 500); // 15% maintenance, 5% reward
        
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        vm.prank(bob);
        clearingHouse.openPosition(100e6, 5, false, 0);

        assertTrue(clearingHouse.isLiquidatable(alice));

        uint256 liquidatorBalanceBefore = usdc.balanceOf(liquidator);
        uint256 protocolFeesBefore = clearingHouse.protocolFees();

        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);

        uint256 liquidatorReward = usdc.balanceOf(liquidator) - liquidatorBalanceBefore;
        uint256 protocolFee = clearingHouse.protocolFees() - protocolFeesBefore;

        // Liquidator gets 5% of remaining margin
        // Protocol gets 95% of remaining margin
        console.log("Liquidator reward:", liquidatorReward);
        console.log("Protocol fee:", protocolFee);

        // Protocol fee should be much larger than liquidator reward (95% vs 5%)
        assertGt(protocolFee, liquidatorReward);
    }

    function test_MultiplePositionsAndLiquidations() public {
        // Open multiple positions
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Close Alice's position normally
        vm.prank(alice);
        clearingHouse.closePosition();

        // Open again
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Move price down for liquidation
        vm.prank(bob);
        clearingHouse.openPosition(300e6, 5, false, 0);

        assertTrue(clearingHouse.isLiquidatable(alice));

        // Liquidate Alice
        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);

        // Verify clean state
        assertEq(clearingHouse.getPosition(alice).margin, 0);
    }
}
