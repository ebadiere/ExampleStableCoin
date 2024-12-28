// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract StableCoin is ERC20Upgradeable, OwnableUpgradeable {
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
        address _engine,
        address _owner
    )
        external
        initializer
    {
        if (_engine == address(0) || _owner == address(0)) revert ZeroAddress();

        __ERC20_init(name, symbol);
        __Ownable_init();
        _transferOwnership(_owner);

        engine = _engine;
    }

    function mint(address to, uint256 amount) external onlyEngine {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyEngine {
        _burn(from, amount);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
