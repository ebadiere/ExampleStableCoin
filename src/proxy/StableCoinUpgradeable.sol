// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract StableCoinUpgradeable is ERC20Upgradeable, OwnableUpgradeable {
    address public engine;

    error OnlyEngine();
    error ZeroAddress();

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _engine
    ) external initializer {
        if (_engine == address(0)) revert ZeroAddress();
        
        __ERC20_init(name, symbol);
        __Ownable_init();
        
        engine = _engine;
    }

    function mint(address to, uint256 amount) external onlyEngine {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyEngine {
        _burn(from, amount);
    }
}
