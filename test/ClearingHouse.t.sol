// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/types/Position.sol";

contract ClearingHouseTest is Test {
    ClearingHouse public clearingHouse;
    VAMM public vamm;
    Vault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public liquidator = address(0x3);

    uint256 public constant INIT_BASE_RESERVE = 100 ether; // 100 vETH
    uint256 public constant INIT_QUOTE_RESERVE = 10000e6;  // 10000 USDC (price = 100)
    uint256 public constant USER_INITIAL_BALANCE = 10000e6; // 10000 USDC
    uint256 public constant PRECISION = 1e18;

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy Vault
        vault = new Vault(address(usdc));

        // Deploy vAMM with initial reserves (price = 100 USDC/ETH)
        vamm = new VAMM(INIT_BASE_RESERVE, INIT_QUOTE_RESERVE);

        // Deploy ClearingHouse
        clearingHouse = new ClearingHouse(address(vault), address(vamm), address(usdc));

        // Set ClearingHouse in Vault and vAMM
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        // Fund users
        usdc.mint(alice, USER_INITIAL_BALANCE);
        usdc.mint(bob, USER_INITIAL_BALANCE);
        usdc.mint(liquidator, USER_INITIAL_BALANCE);

        // Fund vault for payouts (protocol liquidity)
        usdc.mint(address(vault), 100000e6);

        // Approve ClearingHouse to spend user tokens (via vault)
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Unit Tests: Open Position ============

    function test_OpenLongPosition() public {
        uint256 margin = 100e6; // 100 USDC
        uint256 leverage = 5;

        vm.prank(alice);
        clearingHouse.openPosition(margin, leverage, true, 0);

        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, margin);
        assertEq(pos.leverage, leverage);
        assertGt(pos.positionSize, 0); // Long = positive
        assertEq(pos.openNotional, margin * leverage);
    }

    function test_OpenShortPosition() public {
        uint256 margin = 100e6;
        uint256 leverage = 5;

        vm.prank(alice);
        clearingHouse.openPosition(margin, leverage, false, 0);

        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, margin);
        assertLt(pos.positionSize, 0); // Short = negative
    }

    function test_RevertWhen_MarginTooLow() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InvalidMargin.selector);
        clearingHouse.openPosition(1e6, 5, true, 0); // Only 1 USDC
    }

    function test_RevertWhen_LeverageTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InvalidLeverage.selector);
        clearingHouse.openPosition(100e6, 15, true, 0); // 15x > max 10x
    }

    function test_RevertWhen_LeverageZero() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InvalidLeverage.selector);
        clearingHouse.openPosition(100e6, 0, true, 0);
    }

    function test_RevertWhen_PositionAlreadyExists() public {
        vm.startPrank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        vm.expectRevert(ClearingHouse.PositionAlreadyExists.selector);
        clearingHouse.openPosition(100e6, 5, true, 0);
        vm.stopPrank();
    }

    // ============ Unit Tests: Close Position ============

    function test_ClosePositionWithProfit() public {
        // Alice opens long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Bob opens short (moves price up for Alice's long)
        vm.prank(bob);
        clearingHouse.openPosition(500e6, 10, true, 0);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // Alice closes with profit
        vm.prank(alice);
        clearingHouse.closePosition();

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        assertGt(aliceBalanceAfter, aliceBalanceBefore);

        // Position should be cleared
        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, 0);
    }

    function test_ClosePositionWithLoss() public {
        // Alice opens long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Bob opens short (moves price down for Alice's long)
        vm.prank(bob);
        clearingHouse.openPosition(500e6, 10, false, 0);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // Alice closes with loss
        vm.prank(alice);
        clearingHouse.closePosition();

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 payout = aliceBalanceAfter - aliceBalanceBefore;
        // She should get back less than her original margin (100 USDC)
        assertLt(payout, 100e6);
    }

    function test_ClosePositionBreakeven() public {
        // Alice opens and immediately closes
        vm.startPrank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        uint256 balanceBefore = usdc.balanceOf(alice);
        clearingHouse.closePosition();
        uint256 balanceAfter = usdc.balanceOf(alice);
        
        // Should get approximately margin back (some slippage)
        assertApproxEqRel(balanceAfter - balanceBefore, 100e6, 0.01e18); // 1% tolerance
        vm.stopPrank();
    }

    function test_RevertWhen_CloseNoPosition() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.NoPositionExists.selector);
        clearingHouse.closePosition();
    }

    // ============ Unit Tests: Liquidation ============

    function test_LiquidateUnderwaterPosition() public {
        // Alice opens a max leverage long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 10, true, 0);

        // Bob opens short to tank price (stay within liquidity limits)
        vm.prank(bob);
        clearingHouse.openPosition(800e6, 10, false, 0);

        // Check Alice is liquidatable
        assertTrue(clearingHouse.isLiquidatable(alice));

        uint256 liquidatorBalanceBefore = usdc.balanceOf(liquidator);

        // Liquidator liquidates Alice
        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);

        // Liquidator should receive reward
        uint256 liquidatorBalanceAfter = usdc.balanceOf(liquidator);
        assertGe(liquidatorBalanceAfter, liquidatorBalanceBefore);

        // Alice's position should be cleared
        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, 0);
    }

    function test_RevertWhen_LiquidateHealthyPosition() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 2, true, 0); // Low leverage, healthy

        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.PositionNotLiquidatable.selector);
        clearingHouse.liquidatePosition(alice);
    }

    function test_RevertWhen_LiquidateNoPosition() public {
        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.NoPositionExists.selector);
        clearingHouse.liquidatePosition(alice);
    }

    // ============ Unit Tests: View Functions ============

    function test_GetPrice() public view {
        uint256 price = clearingHouse.getPrice();
        // Initial price should be 100 USDC/ETH (10000e6/100e18 * 1e18 = 100e6)
        assertEq(price, 100e6);
    }

    function test_GetUnrealizedPnl() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // Initially PnL should be near zero (small slippage)
        int256 pnl = clearingHouse.getUnrealizedPnl(alice);
        assertApproxEqAbs(pnl, 0, 5e6); // Within 5 USDC
    }

    function test_GetMarginRatio() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        uint256 marginRatio = clearingHouse.getMarginRatio(alice);
        // Initial margin ratio should be around 20% (1/5 leverage)
        assertGt(marginRatio, 1000); // > 10%
    }

    function test_GetVammReserves() public view {
        (uint256 baseReserve, uint256 quoteReserve) = clearingHouse.getVammReserves();
        assertEq(baseReserve, INIT_BASE_RESERVE);
        assertEq(quoteReserve, INIT_QUOTE_RESERVE);
    }

    // ============ Unit Tests: Admin Functions ============

    function test_SetParameters() public {
        clearingHouse.setParameters(20, 5e6, 500, 300);

        assertEq(clearingHouse.maxLeverage(), 20);
        assertEq(clearingHouse.minMargin(), 5e6);
        assertEq(clearingHouse.maintenanceMarginRatio(), 500);
        assertEq(clearingHouse.liquidationRewardRatio(), 300);
    }

    function test_RevertWhen_NonOwnerSetsParameters() public {
        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.setParameters(20, 5e6, 500, 300);
    }

    function test_PauseAndUnpause() public {
        clearingHouse.pause();

        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.openPosition(100e6, 5, true, 0);

        clearingHouse.unpause();

        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
    }

    // ============ Integration Tests ============

    function test_FullLifecycle_LongProfit() public {
        // 1. Alice opens long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // 2. Price moves up (Bob longs)
        vm.prank(bob);
        clearingHouse.openPosition(500e6, 10, true, 0);

        // 3. Alice closes with profit
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearingHouse.closePosition();
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);

        // Alice should profit
        assertGt(aliceBalanceAfter, aliceBalanceBefore);
        console.log("Alice profit:", aliceBalanceAfter - aliceBalanceBefore);
    }

    function test_FullLifecycle_LongLoss() public {
        // 1. Alice opens long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        // 2. Price moves down (Bob shorts)
        vm.prank(bob);
        clearingHouse.openPosition(500e6, 10, false, 0);

        // 3. Alice closes with loss
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearingHouse.closePosition();
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);

        // Alice gets back less than 100 USDC margin
        uint256 payout = aliceBalanceAfter - aliceBalanceBefore;
        assertLt(payout, 100e6);
        console.log("Alice payout:", payout);
    }

    function test_FullLifecycle_Liquidation() public {
        // 1. Alice opens max leverage long
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 10, true, 0);

        // 2. Price drop (within liquidity limits)
        vm.prank(bob);
        clearingHouse.openPosition(800e6, 10, false, 0);

        // 3. Verify liquidatable
        assertTrue(clearingHouse.isLiquidatable(alice));

        // 4. Liquidator liquidates
        uint256 liquidatorBalanceBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        clearingHouse.liquidatePosition(alice);
        uint256 liquidatorBalanceAfter = usdc.balanceOf(liquidator);

        console.log("Liquidator reward:", liquidatorBalanceAfter - liquidatorBalanceBefore);

        // 5. Position cleared
        assertEq(clearingHouse.getPosition(alice).margin, 0);
    }

    function test_MultiUser_OpenCloseSequence() public {
        // Multiple users trade
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        vm.prank(bob);
        clearingHouse.openPosition(200e6, 3, false, 0);

        // Both close
        vm.prank(alice);
        clearingHouse.closePosition();

        vm.prank(bob);
        clearingHouse.closePosition();

        // Both positions cleared
        assertEq(clearingHouse.getPosition(alice).margin, 0);
        assertEq(clearingHouse.getPosition(bob).margin, 0);
    }

    // ============ Edge Cases ============

    function test_EdgeCase_MaxLeveragePosition() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 10, true, 0);

        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.leverage, 10);
    }

    function test_EdgeCase_MinMarginPosition() public {
        vm.prank(alice);
        clearingHouse.openPosition(10e6, 5, true, 0);

        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, 10e6);
    }

    function test_EdgeCase_UnderwaterPayout() public {
        // Alice opens max leverage
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 10, true, 0);

        // Price crash (within liquidity limits)
        vm.prank(bob);
        clearingHouse.openPosition(800e6, 10, false, 0);

        // Alice closes with significant loss
        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearingHouse.closePosition();
        uint256 balanceAfter = usdc.balanceOf(alice);

        // Payout should be less than original margin (significant loss)
        uint256 payout = balanceAfter - balanceBefore;
        assertLt(payout, 100e6);
        console.log("Alice underwater payout:", payout);
    }

    // ============ Access Control Tests ============

    function test_OnlyOwnerCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.pause();
    }

    function test_OnlyOwnerCanUnpause() public {
        clearingHouse.pause();
        
        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.unpause();
    }

    // ============ Fuzz Tests ============

    function testFuzz_OpenPosition(uint256 margin, uint256 leverage, bool isLong) public {
        // Bound inputs to valid ranges
        margin = bound(margin, 10e6, 500e6);
        leverage = bound(leverage, 1, 10);
        
        // For shorts, limit notional to avoid exceeding liquidity
        if (!isLong) {
            uint256 notional = margin * leverage;
            if (notional >= INIT_QUOTE_RESERVE) {
                margin = (INIT_QUOTE_RESERVE - 1e6) / leverage;
                if (margin < 10e6) margin = 10e6;
                leverage = 1; // Reduce leverage to stay within limits
            }
        }

        vm.prank(alice);
        clearingHouse.openPosition(margin, leverage, isLong, 0);

        Position memory pos = clearingHouse.getPosition(alice);
        assertEq(pos.margin, margin);
        assertEq(pos.leverage, leverage);
        
        if (isLong) {
            assertGt(pos.positionSize, 0);
        } else {
            assertLt(pos.positionSize, 0);
        }
    }
}
