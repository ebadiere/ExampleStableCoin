// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./StableCoin.sol";

contract StableCoinEngine is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant LIQUIDATION_THRESHOLD = 150;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant MAX_PRICE_AGE = 1 days;

    mapping(address => Position) public positions;
    address[] private userList;

    IERC20Upgradeable public collateralToken;
    StableCoin public stableCoin;

    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastInteractionTime;
        uint256 lastHealthFactor;
    }

    struct Observation {
        uint256 timestamp;
        uint256 price;
    }

    Observation[] public observations;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Mint(address indexed user, uint256 amount);
    event Burn(address indexed user, uint256 amount);
    event PriceUpdated(uint256 newPrice);
    event PositionLiquidated(
        address indexed user, address indexed liquidator, uint256 debtAmount, uint256 collateralAmount
    );

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

        if (_collateralToken == address(0) || _stableCoin == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        collateralToken = IERC20Upgradeable(_collateralToken);
        stableCoin = StableCoin(_stableCoin);
        _transferOwnership(_owner);
    }

    function depositAndMint(uint256 collateralAmount, uint256 mintAmount) external {
        if (collateralAmount == 0 || mintAmount == 0) revert ZeroAmount();

        _deposit(collateralAmount);
        _mint(mintAmount);

        _updatePosition(msg.sender);
    }

    function burnAndWithdraw(uint256 burnAmount, uint256 withdrawAmount) external {
        _burn(burnAmount);
        _withdraw(withdrawAmount);

        _updatePosition(msg.sender);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _deposit(amount);
        _updatePosition(msg.sender);
    }

    function mint(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _mint(amount);
        _updatePosition(msg.sender);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _withdraw(amount);
        _updatePosition(msg.sender);
    }

    function burn(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _burn(amount);
        _updatePosition(msg.sender);
    }

    function liquidate(address user) external {
        if (!isLiquidatable(user)) revert PositionNotLiquidatable();

        Position storage position = positions[user];
        uint256 debtAmount = position.debtAmount;
        uint256 collateralAmount = position.collateralAmount;

        // Calculate bonus (10% extra collateral)
        uint256 bonusCollateral = (collateralAmount * 10) / 100;
        uint256 totalCollateralToLiquidator = collateralAmount + bonusCollateral;

        // Clear the position
        position.debtAmount = 0;
        position.collateralAmount = 0;
        position.lastInteractionTime = block.timestamp;
        position.lastHealthFactor = type(uint256).max;

        // Transfer assets
        stableCoin.burn(msg.sender, debtAmount);
        collateralToken.safeTransfer(msg.sender, totalCollateralToLiquidator);

        emit PositionLiquidated(user, msg.sender, debtAmount, totalCollateralToLiquidator);
    }

    function updatePrice(uint256 newPrice) external onlyOwner {
        observations.push(Observation({ timestamp: block.timestamp, price: newPrice }));
        emit PriceUpdated(newPrice);
    }

    function _deposit(uint256 amount) internal {
        positions[msg.sender].collateralAmount += amount;
        _addUser(msg.sender);
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function _mint(uint256 amount) internal {
        if (!_hasEnoughCollateral(msg.sender, amount)) revert InsufficientCollateral();
        positions[msg.sender].debtAmount += amount;
        stableCoin.mint(msg.sender, amount);
        emit Mint(msg.sender, amount);
    }

    function _withdraw(uint256 amount) internal {
        Position storage position = positions[msg.sender];
        if (position.collateralAmount < amount) revert InsufficientCollateral();

        position.collateralAmount -= amount;
        collateralToken.safeTransfer(msg.sender, amount);

        if (position.debtAmount > 0) {
            if (!_hasEnoughCollateral(msg.sender, 0)) revert HealthFactorTooLow();
        }

        emit Withdraw(msg.sender, amount);
    }

    function _burn(uint256 amount) internal {
        Position storage position = positions[msg.sender];
        if (position.debtAmount < amount) revert InsufficientDebt();

        position.debtAmount -= amount;
        stableCoin.burn(msg.sender, amount);
        emit Burn(msg.sender, amount);
    }

    function _addUser(address user) internal {
        if (positions[user].lastInteractionTime == 0) {
            userList.push(user);
        }
    }

    function _updatePosition(address user) internal {
        Position storage position = positions[user];
        position.lastInteractionTime = block.timestamp;
        position.lastHealthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
    }

    function _hasEnoughCollateral(address user, uint256 additionalDebt) internal view returns (bool) {
        Position storage position = positions[user];
        uint256 totalDebt = position.debtAmount + additionalDebt;
        if (totalDebt == 0) return true;

        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, totalDebt);
        return healthFactor >= MIN_HEALTH_FACTOR;
    }

    function _calculateHealthFactor(uint256 collateralAmount, uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return type(uint256).max;
        uint256 collateralValue = (collateralAmount * getTWAP()) / 1e8;
        uint256 collateralAdjustedForThreshold = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / debtAmount;
    }

    function getTWAP() public view returns (uint256) {
        if (observations.length == 0) revert PriceTooOld();

        uint256 length = observations.length;
        Observation memory lastObservation = observations[length - 1];

        if (block.timestamp - lastObservation.timestamp > MAX_PRICE_AGE) {
            revert PriceTooOld();
        }

        return lastObservation.price;
    }

    function getUsers() external view returns (address[] memory) {
        return userList;
    }

    function getObservationsCount() external view returns (uint256) {
        return observations.length;
    }

    function isLiquidatable(address user) public view returns (bool) {
        Position memory position = positions[user];
        if (position.debtAmount == 0) return false;

        uint256 healthFactor = _calculateHealthFactor(position.collateralAmount, position.debtAmount);
        return healthFactor < MIN_HEALTH_FACTOR;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;
}
