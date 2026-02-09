// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title GasTest
 * @notice Gas benchmarking tests for the vAMM Perpetual DEX
 */
contract GasTest is Test {
    ClearingHouse public clearingHouse;
    VAMM public vamm;
    Vault public vault;
    MockUSDC public usdc;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new Vault(address(usdc));
        vamm = new VAMM(100 ether, 10000e6);
        clearingHouse = new ClearingHouse(address(vault), address(vamm), address(usdc));
        
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);
        usdc.mint(address(vault), 1000000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_Gas_OpenPosition() public {
        uint256 gasBefore = gasleft();
        
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for openPosition:", gasUsed);
    }

    function test_Gas_ClosePosition() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        uint256 gasBefore = gasleft();
        
        vm.prank(alice);
        clearingHouse.closePosition();
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for closePosition:", gasUsed);
    }

    function test_Gas_GetPrice() public view {
        uint256 gasBefore = gasleft();
        
        clearingHouse.getPrice();
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for getPrice:", gasUsed);
    }

    function test_Gas_GetMarginRatio() public {
        vm.prank(alice);
        clearingHouse.openPosition(100e6, 5, true, 0);

        uint256 gasBefore = gasleft();
        
        clearingHouse.getMarginRatio(alice);
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for getMarginRatio:", gasUsed);
    }

    function test_Gas_VammSwap() public {
        uint256 gasBefore = gasleft();
        
        vm.prank(address(clearingHouse));
        vamm.swapInput(true, 500e6);
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for vamm.swapInput:", gasUsed);
    }

    function test_Gas_VammGetPrice() public view {
        uint256 gasBefore = gasleft();
        
        vamm.getPrice();
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for vamm.getPrice:", gasUsed);
    }
}
