// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract StableCoinProxy is TransparentUpgradeableProxy {
    constructor(
        address _logic,
        address admin_,
        bytes memory _data
    )
        payable
        TransparentUpgradeableProxy(_logic, admin_, _data)
    { }

    function implementation() external view returns (address) {
        return _implementation();
    }
}
