// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "../src/proxy/StableCoinProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract UpgradeStableCoin is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAdmin = vm.envAddress("PROXY_ADMIN");
        address stableCoinProxy = vm.envAddress("STABLECOIN_PROXY");
        address engineProxy = vm.envAddress("ENGINE_PROXY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation contracts
        StableCoin newStableCoinImpl = new StableCoin();
        StableCoinEngine newEngineImpl = new StableCoinEngine();

        // Get ProxyAdmin contract
        ProxyAdmin admin = ProxyAdmin(proxyAdmin);

        // Upgrade proxies
        admin.upgrade(ITransparentUpgradeableProxy(stableCoinProxy), address(newStableCoinImpl));
        admin.upgrade(ITransparentUpgradeableProxy(engineProxy), address(newEngineImpl));

        vm.stopBroadcast();

        console.log("New StableCoin implementation deployed at:", address(newStableCoinImpl));
        console.log("New StableCoinEngine implementation deployed at:", address(newEngineImpl));
        console.log("Proxies upgraded successfully");
    }
}
