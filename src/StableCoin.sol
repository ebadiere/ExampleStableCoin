// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";


contract StableCoin is ERC20Burnable, Ownable {
    constructor(address initialOwner) 
        ERC20("StableCoin", "SC") 
        Ownable(initialOwner) 
    {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }
}