// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Script.sol";
import "../contracts/core/NapFiMetaVault.sol";

contract DeployMetaVault is Script {
    function run() external {
        vm.startBroadcast();
        address asset = 0x...; // e.g. USDC on Base Sepolia
        address aaveAdapter = 0x...;
        address sparkAdapter = 0x...;

        new NapFiMetaVault(asset, aaveAdapter, sparkAdapter);
        vm.stopBroadcast();
    }
}
