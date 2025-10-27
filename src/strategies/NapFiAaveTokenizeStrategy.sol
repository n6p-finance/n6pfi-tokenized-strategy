// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * NapFi Aave Tokenized Strategy (ERC-4626 Wrapper)
 * -------------------------------------------------
 * Wraps the NapFiAaveAdapter inside an ERC-4626-compatible
 * TokenizedStrategy for Octant V2 and Yearn Kalani Vaults.
 * 
 * Limitations:
 * - No external debt handling yet.
 * - ERC-4626 functions (deposit, mint, withdraw, redeem) are inherited
 *   from OpenZeppelin's ERC4626 implementation.
 */

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import { BaseTokenizedStrategy } from "tokenized-strategy/BaseTokenizedStrategy.sol";
import { NapFiSparkAdapter } from "../strategy/SparkAdapter.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

contract NapFiAaveTokenizedStrategy is BaseTokenizedStrategy, ERC4626 {
    NapFiAaveAdapter public adapter;

    constructor(address _asset, address _adapter)
        BaseTokenizedStrategy(_asset, msg.sender)
    {
        adapter = NapFiAaveAdapter(_adapter);
    }
}