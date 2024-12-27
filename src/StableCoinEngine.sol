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

    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 liquidationPrice;    // Price at which position becomes unsafe
        uint256 lastInterestUpdate;
    }

    address public immutable stableCoin;
    address public immutable collateralToken;

    // Core parameters
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public baseCollateralRatio = 150e16; // 150%
    uint256 public liquidationThreshold = 120e16; // 120%
    uint256 public mintFee = 1e16; // 1%
    uint256 public burnFee = 5e15;  // 0.5%    

    uint256 public constant PERIOD = 1 hours; // Time window
    uint256 public constant MAX_PRICE_CHANGE_PERCENTAGE = 10; // 10% max price change
    uint256 public constant MAX_PRICE_AGE = 1 days; // Maximum age of price data
    uint256 public constant MIN_UPDATE_DELAY = 5 minutes; // Minimum time between updates
    
    Observation[] public observations;
    mapping(address => Position) public positions;
    
    event PositionLiquidated(
        address indexed owner,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralLiquidated,
        uint256 bonus
    );
    event Update(uint256 currentPrice);
    event TWAP(uint256 twap);

    error ZeroAddress();
    error SameTokens();
    error InvalidERC20();
    error ZeroPrice();
    error PriceChangeTooBig(uint256 oldPrice, uint256 newPrice);
    error UpdateTooFrequent(uint256 timeSinceLastUpdate, uint256 requiredDelay);
    error StaleData(uint256 oldestTimestamp);
    error InsufficientData();
    error NoData();

    modifier validPrice(uint256 price) {
        if (price == 0) revert ZeroPrice();
        _;
    }

    modifier notTooFrequent() {
        if (observations.length > 0) {
            uint256 timeSinceLastUpdate = block.timestamp - observations[observations.length - 1].timestamp;
            if (timeSinceLastUpdate < MIN_UPDATE_DELAY) {
                revert UpdateTooFrequent(timeSinceLastUpdate, MIN_UPDATE_DELAY);
            }
        }
        _;
    }

    modifier notStaleData() {
        if (observations.length > 0 && block.timestamp - observations[0].timestamp > MAX_PRICE_AGE) {
            revert StaleData(observations[0].timestamp);
        }
        _;
    }

    modifier sufficientData() {
        if (observations.length < 2) revert InsufficientData();
        _;
    }

    modifier hasData() {
        if (observations.length == 0) revert NoData();
        _;
    }

    modifier priceChangeInRange(uint256 newPrice) {
        if (observations.length > 0) {
            uint256 lastPrice = observations[observations.length - 1].price;
            uint256 priceChange = newPrice > lastPrice 
                ? ((newPrice - lastPrice) * 100) / lastPrice 
                : ((lastPrice - newPrice) * 100) / lastPrice;
            
            if (priceChange > MAX_PRICE_CHANGE_PERCENTAGE) {
                revert PriceChangeTooBig(lastPrice, newPrice);
            }
        }
        _;
    }

    constructor(
        address _stableCoin,
        address _collateralToken,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_stableCoin == address(0) || _collateralToken == address(0)) {
            revert ZeroAddress();
        }
        if (_stableCoin == _collateralToken) {
            revert SameTokens();
        }

        // Verify both addresses contain ERC20 contracts
        try ERC20(_stableCoin).totalSupply() {} catch {
            revert InvalidERC20();
        }
        try ERC20(_collateralToken).totalSupply() {} catch {
            revert InvalidERC20();
        }

        stableCoin = _stableCoin;
        collateralToken = _collateralToken;
    }

    function update(uint256 currentPrice) 
        external 
        onlyOwner 
        validPrice(currentPrice)
        notTooFrequent
        priceChangeInRange(currentPrice)
    {
        observations.push(Observation({
            timestamp: block.timestamp,
            price: currentPrice
        }));

        emit Update(currentPrice);
    }
    
    function getTWAP() 
        public 
        view
        sufficientData 
        notStaleData 
        returns (uint256) 
    {
        uint256 timeWeightedPrice;
        uint256 totalTime;
        uint256 lastIndex = observations.length - 1;
        
        // Calculate time-weighted price for all periods except the last one
        for (uint i = 1; i < observations.length; i++) {
            uint256 timeElapsed = observations[i].timestamp - observations[i-1].timestamp;
            timeWeightedPrice += observations[i-1].price * timeElapsed;
            totalTime += timeElapsed;
        }

        // Add the last period using current time
        uint256 lastTimeElapsed = block.timestamp - observations[lastIndex].timestamp;
        timeWeightedPrice += observations[lastIndex].price * lastTimeElapsed;
        totalTime += lastTimeElapsed;
        
        return timeWeightedPrice / totalTime;
    }

    function getLatestPrice() external view hasData returns (uint256) {
        return observations[observations.length - 1].price;
    }

    function getObservationsCount() external view returns (uint256) {
        return observations.length;
    }

    function getCollateralPrice() public view returns (uint256) {
        uint256 twap = getTWAP();
        return twap * PRICE_PRECISION / 1e8;
    }    

    function calculateRequiredCollateral(uint256 mintAmount) public view returns (uint256) {
        uint256 collateralPrice = getCollateralPrice();
        // Both mintAmount and collateralPrice are in PRICE_PRECISION (1e18)
        // baseCollateralRatio is in 1e16 (150e16 = 150%)
        // We multiply by PRICE_PRECISION and divide by 1e16 to maintain precision
        return (mintAmount * baseCollateralRatio * PRICE_PRECISION) / (collateralPrice * 1e18);
    }    

    function isLiquidatable(address user) public view returns (bool) {
        Position storage position = positions[user];
        return position.debtAmount > 0 && position.liquidationPrice > 0 && getTWAP() < position.liquidationPrice;   
    }
}
