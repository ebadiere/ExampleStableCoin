// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./StableCoin.sol";

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
    uint256 public constant PRICE_PRECISION = 1e8;  // Changed from 1e18 to match price feed precision
    uint256 public baseCollateralRatio = 150e16; // 150%
    uint256 public liquidationThreshold = 120e16; // 120%
    uint256 public mintFee = 1e16; // 1%
    uint256 public burnFee = 5e15;  // 0.5%    
    uint256 public liquidationBonus = 10e16; // 10% bonus for liquidators

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
    event PositionUpdated(
        address indexed user,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 liquidationPrice
    );

    error ZeroAddress();
    error SameTokens();
    error InvalidERC20();
    error ZeroPrice();
    error PriceChangeTooBig(uint256 oldPrice, uint256 newPrice);
    error UpdateTooFrequent(uint256 timeSinceLastUpdate, uint256 requiredDelay);
    error StaleData(uint256 oldestTimestamp);
    error InsufficientData();
    error NoData();
    error NotLiquidatable();
    error InsufficientRepayment();

    modifier validPrice(uint256 price) {
        if (price == 0) revert ZeroPrice();
        _;
    }

    modifier hasData() {
        if (observations.length == 0) revert NoData();
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
        if (observations.length > 0 && block.timestamp - observations[observations.length - 1].timestamp > MAX_PRICE_AGE) {
            revert StaleData(observations[observations.length - 1].timestamp);
        }
        _;
    }

    modifier sufficientData() {
        if (observations.length < 2) revert InsufficientData();
        _;
    }

    modifier priceChangeInRange(uint256 newPrice) {
        if (observations.length > 0) {
            uint256 oldPrice = observations[observations.length - 1].price;
            uint256 maxChange = oldPrice * MAX_PRICE_CHANGE_PERCENTAGE / 100;
            uint256 minPrice = oldPrice > maxChange ? oldPrice - maxChange : 0;
            uint256 maxPrice = oldPrice + maxChange;
            if (newPrice < minPrice || newPrice > maxPrice) {
                revert PriceChangeTooBig(oldPrice, newPrice);
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
        notStaleData
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
        hasData
        sufficientData 
        notStaleData 
        returns (uint256) 
    {
        uint256 twap = calculateTWAP();
        return twap;  // Price is already in 1e8 precision
    }

    function getLatestPrice() external view hasData returns (uint256) {
        return observations[observations.length - 1].price;
    }

    function getObservationsCount() external view returns (uint256) {
        return observations.length;
    }

    function getCollateralPrice() public view hasData returns (uint256) {
        uint256 twap = getTWAP();
        return twap * 1e18 / PRICE_PRECISION;  // Convert from 1e8 to 1e18
    }    

    function calculateRequiredCollateral(uint256 mintAmount) public view hasData returns (uint256) {
        // Example: Mint 100 stablecoins at $1 each with 150% collateral ratio
        // collateralPrice = $50 (in 1e8 precision)
        // mintAmount = 100e18, baseCollateralRatio = 150e16
        // numerator = 100e18 * 150e16 = 15000e34
        // denominator = 50e8 = 5e9
        // result = (15000e34) / (5e9) = 2.926829268292682926e18
        uint256 collateralPrice = getTWAP();
        uint256 numerator = mintAmount * baseCollateralRatio;
        uint256 denominator = collateralPrice * 1e10;  // Scale up to match numerator precision
        return numerator / denominator;
    }    

    function isLiquidatable(address user) public view hasData returns (bool) {
        Position storage position = positions[user];
        return position.debtAmount > 0 && position.liquidationPrice > 0 && getTWAP() < position.liquidationPrice;   
    }

    function liquidate(address user, uint256 debtToRepay) external {
        // Check if position is liquidatable
        if (!isLiquidatable(user)) {
            revert NotLiquidatable();
        }

        Position storage position = positions[user];
        if (debtToRepay > position.debtAmount) {
            revert InsufficientRepayment();
        }

        // Calculate collateral to liquidate based on current TWAP
        uint256 collateralPrice = getTWAP();
        uint256 collateralToLiquidate = (debtToRepay * PRICE_PRECISION) / collateralPrice;

        // Calculate bonus (10% of liquidated collateral)
        uint256 bonus = (collateralToLiquidate * liquidationBonus) / 1e18;
        uint256 totalCollateralToTransfer = collateralToLiquidate + bonus;

        // Ensure we don't liquidate more than available
        require(totalCollateralToTransfer <= position.collateralAmount, "Insufficient collateral in position");

        // Transfer stablecoins from liquidator to contract
        SafeERC20.safeTransferFrom(IERC20(stableCoin), msg.sender, address(this), debtToRepay);

        // Update position
        position.collateralAmount -= totalCollateralToTransfer;
        position.debtAmount -= debtToRepay;

        // If position is fully liquidated, reset liquidation price
        if (position.debtAmount == 0) {
            position.liquidationPrice = 0;
            position.collateralAmount = 0;
        } else {
            // Recalculate liquidation price for remaining position
            uint256 scaledDebtValue = position.debtAmount * PRICE_PRECISION;
            uint256 numerator = scaledDebtValue * liquidationThreshold;
            position.liquidationPrice = numerator / position.collateralAmount / 1e18;
        }

        emit PositionLiquidated(
            user,
            msg.sender,
            debtToRepay,
            collateralToLiquidate,
            bonus
        );

        emit PositionUpdated(
            user,
            position.collateralAmount,
            position.debtAmount,
            position.liquidationPrice
        );

        // Burn the repaid debt
        IStableCoin(stableCoin).burn(debtToRepay);

        // Transfer collateral to liquidator
        SafeERC20.safeTransfer(IERC20(collateralToken), msg.sender, totalCollateralToTransfer);
    }

    function depositAndMint(uint256 collateralAmount, uint256 mintAmount) external {
        // Check that the collateral amount is sufficient
        uint256 requiredCollateral = calculateRequiredCollateral(mintAmount);
        require(collateralAmount >= requiredCollateral, "Insufficient collateral");

        // Calculate liquidation price (120% of the debt value in collateral terms)
        // Example: 100 stablecoins with 3 collateral tokens and 120% threshold
        // debtValue = 100e18 * 1e8 = 100e26
        // liquidationThreshold = 120e16 (120%)
        // liquidationPrice = (100e26 * 120e16) / (3e18 * 1e18) = 40e6 ($40)
        uint256 scaledDebtValue = mintAmount * PRICE_PRECISION;
        uint256 numerator = scaledDebtValue * liquidationThreshold;
        uint256 liquidationPrice = numerator / collateralAmount / 1e18;

        // Transfer collateral from user
        SafeERC20.safeTransferFrom(IERC20(collateralToken), msg.sender, address(this), collateralAmount);

        // Update position
        Position storage position = positions[msg.sender];
        position.collateralAmount += collateralAmount;
        position.debtAmount += mintAmount;
        position.liquidationPrice = liquidationPrice;
        position.lastInterestUpdate = block.timestamp;

        // Mint stablecoins
        IStableCoin(stableCoin).mint(msg.sender, mintAmount);

        emit PositionUpdated(msg.sender, position.collateralAmount, position.debtAmount, position.liquidationPrice);
    }

    function calculateTWAP() internal view returns (uint256) {
        // Calculate time-weighted average price, maintaining 1e8 precision
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
        
        return timeWeightedPrice / totalTime;  // Price is in 1e8 precision
    }
}
