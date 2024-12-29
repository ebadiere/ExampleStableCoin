// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./StableCoin.sol";

contract StableCoinEngine is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Constants are already optimized by being actual constants
    uint256 public constant LIQUIDATION_THRESHOLD = 150;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant MAX_PRICE_AGE = 1 days;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant PRICE_PRECISION = 1e8;

    // Pack related storage variables together
    struct Position {
        uint96 collateralAmount;  // Reduced from uint256 since it's bounded by token supply
        uint96 debtAmount;       // Reduced from uint256 since it's bounded by token supply
        uint32 lastInteractionTime; // Reduced from uint256 since timestamp fits in uint32
        uint32 lastHealthFactor;   // Reduced from uint256 since we can scale this down
    }

    struct Observation {
        uint32 timestamp;  // Reduced from uint256 since timestamp fits in uint32
        uint224 price;    // Reduced from uint256 since price with 8 decimals fits in uint224
    }

    // Storage variables
    mapping(address => Position) public positions;
    address[] private userList;
    Observation[] public observations;
    IERC20Upgradeable public collateralToken;
    StableCoin public stableCoin;

    // Events
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Mint(address indexed user, uint256 amount);
    event Burn(address indexed user, uint256 amount);
    event PriceUpdated(uint256 newPrice);
    event PositionLiquidated(
        address indexed user, address indexed liquidator, uint256 debtAmount, uint256 collateralAmount
    );

    // Custom errors
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientDebt();
    error HealthFactorTooLow();
    error PositionNotLiquidatable();
    error PriceTooOld();
    error ZeroAddress();
    error InvalidERC20();

    function initialize(address _collateralToken, address _stableCoin, address _owner) external initializer {
        __Ownable_init();

        // Use assembly for more efficient zero address checks
        assembly {
            if or(or(iszero(_collateralToken), iszero(_stableCoin)), iszero(_owner)) {
                mstore(0x00, 0xd92e233d) // bytes4(keccak256("ZeroAddress()"))
                revert(0x00, 0x04)
            }
        }

        collateralToken = IERC20Upgradeable(_collateralToken);
        stableCoin = StableCoin(_stableCoin);
        _transferOwnership(_owner);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        Position storage position = positions[msg.sender];
        position.collateralAmount = uint96(uint256(position.collateralAmount) + amount);
        
        if (position.lastInteractionTime == 0) {
            userList.push(msg.sender);
        }

        // Update position metadata
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14);

        // External call last
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        Position storage position = positions[msg.sender];
        if (uint256(position.collateralAmount) < amount) revert InsufficientCollateral();

        unchecked {
            position.collateralAmount = uint96(uint256(position.collateralAmount) - amount);
        }

        if (position.debtAmount > 0) {
            if (!_hasEnoughCollateral(msg.sender, 0)) revert HealthFactorTooLow();
        }

        // Update position metadata
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14);

        // External call last
        collateralToken.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, amount);
    }

    function mint(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        Position storage position = positions[msg.sender];
        if (!_hasEnoughCollateral(msg.sender, amount)) revert InsufficientCollateral();
        
        position.debtAmount = uint96(uint256(position.debtAmount) + amount);

        // Update position metadata
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14);

        // External call last
        stableCoin.mint(msg.sender, amount);
        
        emit Mint(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        Position storage position = positions[msg.sender];
        if (uint256(position.debtAmount) < amount) revert InsufficientDebt();

        unchecked {
            position.debtAmount = uint96(uint256(position.debtAmount) - amount);
        }

        // Update position metadata
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14);

        // External call last
        stableCoin.burn(msg.sender, amount);
        
        emit Burn(msg.sender, amount);
    }

    function depositAndMint(uint256 collateralAmount, uint256 mintAmount) external {
        if (collateralAmount == 0 || mintAmount == 0) revert ZeroAmount();

        // Cache storage pointer
        Position storage position = positions[msg.sender];
        
        // Update position in memory first
        position.collateralAmount = uint96(uint256(position.collateralAmount) + collateralAmount);
        
        // Verify collateral before minting
        if (!_hasEnoughCollateral(msg.sender, mintAmount)) revert InsufficientCollateral();
        position.debtAmount = uint96(uint256(position.debtAmount) + mintAmount);

        // Add user if new
        if (position.lastInteractionTime == 0) {
            userList.push(msg.sender);
        }

        // Update timestamp and health factor
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14); // Scale down by 1e14 to fit in uint32

        // External calls last to prevent reentrancy
        collateralToken.safeTransferFrom(msg.sender, address(this), collateralAmount);
        stableCoin.mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, collateralAmount);
        emit Mint(msg.sender, mintAmount);
    }

    function burnAndWithdraw(uint256 burnAmount, uint256 withdrawAmount) external {
        Position storage position = positions[msg.sender];
        
        // Check debt first
        if (uint256(position.debtAmount) < burnAmount) revert InsufficientDebt();
        if (uint256(position.collateralAmount) < withdrawAmount) revert InsufficientCollateral();

        // Update state
        unchecked {
            // Safe because we checked above
            position.debtAmount = uint96(uint256(position.debtAmount) - burnAmount);
            position.collateralAmount = uint96(uint256(position.collateralAmount) - withdrawAmount);
        }

        // Check health factor if there's remaining debt
        if (position.debtAmount > 0) {
            if (!_hasEnoughCollateral(msg.sender, 0)) revert HealthFactorTooLow();
        }

        // Update position metadata
        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        position.lastInteractionTime = uint32(block.timestamp);
        position.lastHealthFactor = uint32(healthFactor / 1e14);

        // External calls last
        stableCoin.burn(msg.sender, burnAmount);
        collateralToken.safeTransfer(msg.sender, withdrawAmount);

        emit Burn(msg.sender, burnAmount);
        emit Withdraw(msg.sender, withdrawAmount);
    }

    function liquidate(address user) external {
        if (!isLiquidatable(user)) revert PositionNotLiquidatable();

        Position storage position = positions[user];
        uint256 debtAmount = position.debtAmount;
        uint256 collateralAmount = position.collateralAmount;

        unchecked {
            // Calculate bonus (10% extra collateral)
            uint256 bonusCollateral = (collateralAmount * LIQUIDATION_BONUS) / 100;
            uint256 totalCollateralToLiquidator = collateralAmount + bonusCollateral;

            // Clear the position
            position.debtAmount = 0;
            position.collateralAmount = 0;
            position.lastInteractionTime = uint32(block.timestamp);
            position.lastHealthFactor = type(uint32).max;

            // External calls last
            stableCoin.burn(msg.sender, debtAmount);
            collateralToken.safeTransfer(msg.sender, totalCollateralToLiquidator);

            emit PositionLiquidated(user, msg.sender, debtAmount, totalCollateralToLiquidator);
        }
    }

    function updatePrice(uint256 newPrice) external onlyOwner {
        observations.push(Observation({
            timestamp: uint32(block.timestamp),
            price: uint224(newPrice)
        }));
        emit PriceUpdated(newPrice);
    }

    function _hasEnoughCollateral(address user, uint256 additionalDebt) internal view returns (bool) {
        Position storage position = positions[user];
        uint256 totalDebt = uint256(position.debtAmount) + additionalDebt;
        if (totalDebt == 0) return true;

        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, totalDebt);
        return healthFactor >= MIN_HEALTH_FACTOR;
    }

    function _calculateHealthFactor(uint256 collateralAmount, uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return type(uint256).max;
        
        unchecked {
            // These operations cannot overflow due to the bounds on collateralAmount and price
            uint256 collateralValue = (collateralAmount * getTWAP()) / PRICE_PRECISION;
            uint256 collateralAdjustedForThreshold = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
            return (collateralAdjustedForThreshold * 1e18) / debtAmount;
        }
    }

    function getTWAP() public view returns (uint256) {
        uint256 length = observations.length;
        if (length == 0) revert PriceTooOld();

        Observation memory lastObservation = observations[length - 1];
        if (block.timestamp - lastObservation.timestamp > MAX_PRICE_AGE) {
            revert PriceTooOld();
        }

        return lastObservation.price;
    }

    function getUsers() external view returns (address[] memory) {
        return userList;
    }

    function isLiquidatable(address user) public view returns (bool) {
        Position memory position = positions[user];
        if (position.debtAmount == 0) return false;

        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        return healthFactor < MIN_HEALTH_FACTOR;
    }
}
