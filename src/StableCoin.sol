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
    ) external initializer {
        // Use assembly for more efficient zero address check
        assembly {
            if or(iszero(_engine), iszero(_owner)) {
                // Store left-padded selector with push4, save some gas
                mstore(0x00, 0xd92e233d) // bytes4(keccak256("ZeroAddress()"))
                revert(0x00, 0x04)
            }
        }

        __ERC20_init(name, symbol);
        __Ownable_init();
        _transferOwnership(_owner);

        engine = _engine;
    }

    function mint(address to, uint256 amount) external onlyEngine {
        // Skip redundant zero amount check in _mint since ERC20Upgradeable already does it
        unchecked {
            // Overflow is impossible because the sum is guaranteed to be less than total supply
            // which is checked in ERC20Upgradeable._mint
            _mint(to, amount);
        }
    }

    function burn(address from, uint256 amount) external onlyEngine {
        // Skip redundant zero amount check in _burn since ERC20Upgradeable already does it
        unchecked {
            // Underflow is impossible because ERC20Upgradeable._burn already checks for sufficient balance
            _burn(from, amount);
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
