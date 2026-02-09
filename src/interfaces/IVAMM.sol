// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVAMM {
    function swapInput(bool isLong, uint256 quoteAmount) external returns (uint256 baseAmount);
    function swapOutput(bool isLong, uint256 baseAmount) external returns (uint256 quoteAmount);
    function getPrice() external view returns (uint256);
    function getReserves() external view returns (uint256 baseReserve, uint256 quoteReserve);
    function getOutputPrice(bool isLong, uint256 baseAmount) external view returns (uint256 quoteAmount);
    function getInputPrice(bool isLong, uint256 quoteAmount) external view returns (uint256 baseAmount);
}
