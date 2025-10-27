// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IMorpho
 * @notice Interface for interacting with the Morpho protocol for supply and withdrawal of assets.
 */
interface IMorpho {
    // supply underlying asset into Morpho (onBehalfOf is adapter)
    function supply(address asset, uint256 amount, address onBehalfOf) external;

    // withdraw underlying from Morpho back to 'to', returns amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    // returns the current P2P index for an asset (scaled by 1e27)
    function getP2PIndex(address asset) external view returns (uint256);

    // returns total underlying supplied on behalf of a user (in underlying units)
    function getTotalSupplied(address asset, address user) external view returns (uint256);
}
