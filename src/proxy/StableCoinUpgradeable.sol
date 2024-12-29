// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title StableCoinUpgradeable
 * @dev Upgradeable implementation of the StableCoin contract.
 * This contract handles the core ERC20 functionality with minting and burning controlled by an engine.
 */
contract StableCoinUpgradeable is ERC20Upgradeable, OwnableUpgradeable {
    /// @dev The engine address that has permission to mint and burn tokens
    address public engine;

    /// @dev Custom errors are already gas efficient
    error OnlyEngine();
    error ZeroAddress();

    /// @dev Cache the engine check in a modifier to save gas
    modifier onlyEngine() {
        if (msg.sender != engine) {
            // Using assembly for more efficient error handling
            assembly {
                // Store left-padded selector
                mstore(0x00, 0x1a0eff22) // bytes4(keccak256("OnlyEngine()"))
                revert(0x00, 0x04)
            }
        }
        _;
    }

    /**
     * @dev Initializes the contract with a name, symbol, and engine address
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param _engine The address of the engine that can mint and burn tokens
     */
    function initialize(
        string memory name,
        string memory symbol,
        address _engine
    ) external initializer {
        // Use assembly for more efficient zero address check
        assembly {
            if iszero(_engine) {
                // Store left-padded selector
                mstore(0x00, 0xd92e233d) // bytes4(keccak256("ZeroAddress()"))
                revert(0x00, 0x04)
            }
        }

        __ERC20_init(name, symbol);
        __Ownable_init();

        engine = _engine;
    }

    /**
     * @dev Mints new tokens. Can only be called by the engine.
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyEngine {
        // Skip redundant zero amount check since _mint already does it
        unchecked {
            // Overflow is impossible because the sum is guaranteed to be less than total supply
            // which is checked in ERC20Upgradeable._mint
            _mint(to, amount);
        }
    }

    /**
     * @dev Burns tokens. Can only be called by the engine.
     * @param from The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyEngine {
        // Skip redundant zero amount check since _burn already does it
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
    uint256[49] private __gap;
}
