// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VAMM.sol";

contract VAMMTest is Test {
    VAMM public vamm;
    address public clearingHouse = address(0x1);
    
    uint256 public constant INIT_BASE = 100 ether;   // 100 vETH
    uint256 public constant INIT_QUOTE = 10000e6;    // 10000 USDC
    uint256 public constant PRECISION = 1e18;

    function setUp() public {
        vamm = new VAMM(INIT_BASE, INIT_QUOTE);
        vamm.setClearingHouse(clearingHouse);
    }

    // ============ Initialization Tests ============

    function test_InitialReserves() public view {
        (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
        assertEq(baseReserve, INIT_BASE);
        assertEq(quoteReserve, INIT_QUOTE);
    }

    function test_InitialPrice() public view {
        uint256 price = vamm.getPrice();
        // Price = 10000 / 100 = 100 USDC/ETH (scaled by PRECISION)
        // But we need to account for decimal differences
        // 10000e6 / 100e18 * 1e18 = 10000e6 * 1e18 / 100e18 = 10000e6 / 100 = 100e6
        // Wait, let me recalculate: (vQuote * PRECISION) / vBase
        // = (10000e6 * 1e18) / 100e18 = 10000e6 / 100 = 100e6
        assertEq(price, 100e6);
    }

    function test_InitialK() public view {
        uint256 k = vamm.k();
        assertEq(k, INIT_BASE * INIT_QUOTE);
    }

    // ============ Swap Input Tests (Opening Positions) ============

    function test_SwapInput_Long() public {
        uint256 quoteAmount = 500e6; // 500 USDC
        
        vm.prank(clearingHouse);
        uint256 baseReceived = vamm.swapInput(true, quoteAmount);
        
        // Expected: newQuote = 10500, newBase = k / 10500 = 952.38...
        // baseReceived = 100 - 95.238 = 4.762 ETH approximately
        assertGt(baseReceived, 0);
        
        // Verify reserves updated
        (uint256 newBase, uint256 newQuote) = vamm.getReserves();
        assertEq(newQuote, INIT_QUOTE + quoteAmount);
        assertLt(newBase, INIT_BASE);
    }

    function test_SwapInput_Short() public {
        uint256 quoteAmount = 500e6;
        
        vm.prank(clearingHouse);
        uint256 baseSold = vamm.swapInput(false, quoteAmount);
        
        assertGt(baseSold, 0);
        
        // Verify reserves updated
        (uint256 newBase, uint256 newQuote) = vamm.getReserves();
        assertEq(newQuote, INIT_QUOTE - quoteAmount);
        assertGt(newBase, INIT_BASE);
    }

    // ============ Swap Output Tests (Closing Positions) ============

    function test_SwapOutput_CloseLong() public {
        // First open a long
        vm.prank(clearingHouse);
        uint256 baseReceived = vamm.swapInput(true, 500e6);
        
        // Then close it
        vm.prank(clearingHouse);
        uint256 quoteReceived = vamm.swapOutput(true, baseReceived);
        
        // Should get approximately same quote back (minus price impact)
        assertApproxEqRel(quoteReceived, 500e6, 0.05e18); // 5% tolerance for slippage
    }

    function test_SwapOutput_CloseShort() public {
        // First open a short
        vm.prank(clearingHouse);
        uint256 baseSold = vamm.swapInput(false, 500e6);
        
        // Then close it
        vm.prank(clearingHouse);
        uint256 quotePaid = vamm.swapOutput(false, baseSold);
        
        // Should pay approximately same quote back
        assertApproxEqRel(quotePaid, 500e6, 0.05e18);
    }

    // ============ Price Discovery Tests ============

    function test_PriceImpact_LargeTrade() public {
        uint256 priceBefore = vamm.getPrice();
        
        // Large long trade
        vm.prank(clearingHouse);
        vamm.swapInput(true, 2000e6);
        
        uint256 priceAfter = vamm.getPrice();
        
        // Price should increase after long
        assertGt(priceAfter, priceBefore);
    }

    function test_PriceImpact_SmallTrade() public {
        uint256 priceBefore = vamm.getPrice();
        
        // Small long trade
        vm.prank(clearingHouse);
        vamm.swapInput(true, 10e6);
        
        uint256 priceAfter = vamm.getPrice();
        
        // Price should increase slightly
        assertGt(priceAfter, priceBefore);
        // But not by much
        assertApproxEqRel(priceAfter, priceBefore, 0.01e18); // Within 1%
    }

    // ============ View Function Tests ============

    function test_GetInputPrice() public view {
        uint256 baseAmount = vamm.getInputPrice(true, 500e6);
        assertGt(baseAmount, 0);
    }

    function test_GetOutputPrice() public {
        // First create a position
        vm.prank(clearingHouse);
        uint256 baseReceived = vamm.swapInput(true, 500e6);
        
        // Get output price
        uint256 quoteAmount = vamm.getOutputPrice(true, baseReceived);
        assertGt(quoteAmount, 0);
    }

    // ============ Access Control Tests ============

    function test_RevertWhen_NonClearingHouseSwaps() public {
        vm.expectRevert(VAMM.OnlyClearingHouse.selector);
        vamm.swapInput(true, 500e6);
    }

    function test_RevertWhen_SetClearingHouseTwice() public {
        vm.expectRevert("Already set");
        vamm.setClearingHouse(address(0x2));
    }

    // ============ Edge Cases ============

    function test_RevertWhen_ZeroAmount() public {
        vm.prank(clearingHouse);
        vm.expectRevert(VAMM.ZeroAmount.selector);
        vamm.swapInput(true, 0);
    }

    function test_GetInputPrice_Zero() public view {
        uint256 result = vamm.getInputPrice(true, 0);
        assertEq(result, 0);
    }

    function test_GetOutputPrice_Zero() public view {
        uint256 result = vamm.getOutputPrice(true, 0);
        assertEq(result, 0);
    }

    // ============ Constant Product Invariant ============

    function test_KRemainsConstant() public {
        uint256 kBefore = vamm.k();
        
        vm.startPrank(clearingHouse);
        vamm.swapInput(true, 500e6);
        vamm.swapInput(false, 300e6);
        vm.stopPrank();
        
        uint256 kAfter = vamm.k();
        
        // K should remain constant
        assertEq(kAfter, kBefore);
    }

    // ============ Fuzz Tests ============

    function testFuzz_SwapInput(uint256 quoteAmount, bool isLong) public {
        // Bound to reasonable amounts (to avoid overflow/underflow)
        quoteAmount = bound(quoteAmount, 1e6, 5000e6);
        
        vm.prank(clearingHouse);
        uint256 baseAmount = vamm.swapInput(isLong, quoteAmount);
        
        assertGt(baseAmount, 0);
        
        // Verify K is preserved
        (uint256 newBase, uint256 newQuote) = vamm.getReserves();
        assertApproxEqRel(newBase * newQuote, vamm.k(), 0.001e18); // Within 0.1%
    }
}
