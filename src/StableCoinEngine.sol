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

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


/**
 * @title StableCoinEngine
 * @author Eric Badiere
 * @notice Engine for StableCoin. This contract contains the logic for the StableCoin protocol.
 * It will use a time weighted average to determine the value of the collateral. It is assumed that some 
 * external process or oracle will run the update function.
 */

 contract StableCoinEngine is Ownable {

    struct Observation {
        uint256 timestamp;
        uint256 price;
    }

    address public stableCoin;
    address public collateralToken;

    uint256 public constant PERIOD = 1 hours; // Time window
    Observation[] public observations;    

    event Update(uint256 currentPrice);
    event TWAP(uint256 twap);

    constructor(
        address _stableCoin,
        address _collateralToken,
        address initialOwner
    ) Ownable(initialOwner) {
        stableCoin = _stableCoin;
        collateralToken = _collateralToken;
    }

    function update(uint256 currentPrice) external {
        observations.push(Observation({
            timestamp: block.timestamp,
            price: currentPrice
        }));

        emit Update(currentPrice);
    }
    
    function getTWAP() external returns (uint256) {
        uint256 timeWeightedPrice;
        uint256 totalTime;
        
        for (uint i = 1; i < observations.length; i++) {
            uint256 timeElapsed = observations[i].timestamp - observations[i-1].timestamp;
            timeWeightedPrice += observations[i-1].price * timeElapsed;
            totalTime += timeElapsed;
        }
        
        uint256 twap = timeWeightedPrice / totalTime;
        emit TWAP(twap);
        return twap;
    }
 }
