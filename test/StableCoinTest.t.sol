// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";

contract StableCoinTest is Test {
    StableCoin public stableCoin;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        stableCoin = new StableCoin(owner);
    }

    // Tests will be added as StableCoin functionality is built out
}
