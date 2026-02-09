// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Position {
    uint256 margin;           // Collateral in quote asset (e.g., USDC)
    int256 positionSize;      // Virtual base asset amount (+long / -short)
    uint256 openNotional;     // Notional value at open time
    uint256 leverage;         // Leverage multiplier
    uint256 entryPrice;       // Average entry price (openNotional / |positionSize|)
    uint256 openTimestamp;    // Block timestamp when position was opened
}
