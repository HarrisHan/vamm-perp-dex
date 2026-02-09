// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";
import "../src/VAMM.sol";
import "../src/Vault.sol";

/**
 * @title Deploy
 * @notice Deployment script for vAMM Perpetual DEX
 * 
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy --rpc-url <RPC_URL> --broadcast --verify
 * 
 * Environment variables:
 *   PRIVATE_KEY - Deployer private key
 *   QUOTE_ASSET - Address of quote asset (e.g., USDC)
 *   INIT_BASE_RESERVE - Initial vAMM base reserve (e.g., 100 ether for 100 vETH)
 *   INIT_QUOTE_RESERVE - Initial vAMM quote reserve (e.g., 10000e6 for 10000 USDC)
 */
contract Deploy is Script {
    function run() external {
        // Load config from environment
        address quoteAsset = vm.envAddress("QUOTE_ASSET");
        uint256 initBaseReserve = vm.envUint("INIT_BASE_RESERVE");
        uint256 initQuoteReserve = vm.envUint("INIT_QUOTE_RESERVE");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Vault
        Vault vault = new Vault(quoteAsset);
        console.log("Vault deployed at:", address(vault));

        // 2. Deploy vAMM
        VAMM vamm = new VAMM(initBaseReserve, initQuoteReserve);
        console.log("VAMM deployed at:", address(vamm));

        // 3. Deploy ClearingHouse
        ClearingHouse clearingHouse = new ClearingHouse(
            address(vault),
            address(vamm),
            quoteAsset
        );
        console.log("ClearingHouse deployed at:", address(clearingHouse));

        // 4. Set ClearingHouse in Vault and vAMM
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        console.log("\n=== Deployment Complete ===");
        console.log("Quote Asset:", quoteAsset);
        console.log("Initial Price:", initQuoteReserve * 1e18 / initBaseReserve);

        vm.stopBroadcast();
    }
}

/**
 * @title DeployTestnet
 * @notice Deploy with mock USDC for testnet
 */
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Default values for testnet
        uint256 initBaseReserve = 100 ether;  // 100 vETH
        uint256 initQuoteReserve = 100000e6;  // 100000 USDC (price = 1000 USDC/ETH)

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock USDC
        MockUSDC usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));

        // Deploy Vault
        Vault vault = new Vault(address(usdc));
        console.log("Vault deployed at:", address(vault));

        // Deploy vAMM
        VAMM vamm = new VAMM(initBaseReserve, initQuoteReserve);
        console.log("VAMM deployed at:", address(vamm));

        // Deploy ClearingHouse
        ClearingHouse clearingHouse = new ClearingHouse(
            address(vault),
            address(vamm),
            address(usdc)
        );
        console.log("ClearingHouse deployed at:", address(clearingHouse));

        // Set ClearingHouse
        vault.setClearingHouse(address(clearingHouse));
        vamm.setClearingHouse(address(clearingHouse));

        // Mint some USDC to deployer for testing
        usdc.mint(msg.sender, 1000000e6);

        // Seed Vault with initial liquidity
        usdc.mint(address(vault), 10000000e6);

        console.log("\n=== Testnet Deployment Complete ===");
        console.log("Initial Price: 1000 USDC/ETH");

        vm.stopBroadcast();
    }
}

// Import mock for testnet deployment
import "../src/mocks/MockUSDC.sol";
