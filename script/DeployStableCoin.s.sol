// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "../src/proxy/StableCoinProxy.sol";

contract DeployStableCoin is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAdmin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contracts
        StableCoin stableCoinImpl = new StableCoin();
        StableCoinEngine engineImpl = new StableCoinEngine();

        // Prepare initialization data
        bytes memory stableCoinData =
            abi.encodeWithSelector(StableCoin.initialize.selector, "StableCoin", "SC", address(engineImpl));

        // Deploy StableCoin proxy first
        StableCoinProxy stableCoinProxy = new StableCoinProxy(address(stableCoinImpl), proxyAdmin, stableCoinData);

        // Then deploy Engine proxy with correct stablecoin address
        bytes memory engineData = abi.encodeWithSelector(
            StableCoinEngine.initialize.selector,
            address(0), // Set your collateral token address here
            address(stableCoinProxy)
        );

        StableCoinProxy engineProxy = new StableCoinProxy(address(engineImpl), proxyAdmin, engineData);

        vm.stopBroadcast();

        console.log("StableCoin implementation deployed at:", address(stableCoinImpl));
        console.log("StableCoinEngine implementation deployed at:", address(engineImpl));
        console.log("StableCoin proxy deployed at:", address(stableCoinProxy));
        console.log("StableCoinEngine proxy deployed at:", address(engineProxy));
    }
}
