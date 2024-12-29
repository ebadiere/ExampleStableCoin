// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title StableCoinProxy
 * @dev Transparent proxy for StableCoin implementation. Inherits OpenZeppelin's TransparentUpgradeableProxy.
 * The proxy is immutable and can only be initialized once. All function calls are delegated to the implementation
 * contract except admin functions which are only accessible by the admin.
 */
contract StableCoinProxy is TransparentUpgradeableProxy {
    constructor(
        address _logic,
        address admin_,
        bytes memory _data
    ) payable TransparentUpgradeableProxy(_logic, admin_, _data) {
        // Use assembly to validate parameters more efficiently
        assembly {
            if or(iszero(_logic), iszero(admin_)) {
                // Store left-padded selector
                mstore(0x00, 0xd92e233d) // bytes4(keccak256("ZeroAddress()"))
                revert(0x00, 0x04)
            }
        }
    }
}
