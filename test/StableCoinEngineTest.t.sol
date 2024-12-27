// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StableCoinEngineTest is Test {
    StableCoin public stableCoin;
    StableCoinEngine public engine;
    MockERC20 public collateral;
    address public owner;
    address public user;
    address public liquidator;

    event Update(uint256 currentPrice);
    event TWAP(uint256 twap);
    event PositionLiquidated(
        address indexed owner,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralLiquidated,
        uint256 bonus
    );
    event PositionUpdated(
        address indexed user,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 liquidationPrice
    );

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        liquidator = address(0x2);
        collateral = new MockERC20("Mock Token", "MTK");
        stableCoin = new StableCoin(owner);
        engine = new StableCoinEngine(
            address(stableCoin),
            address(collateral),
            owner
        );

        // Set up roles
        stableCoin.transferOwnership(address(engine));

        // Mint collateral tokens to user
        collateral.mint(user, 1000e18);
        collateral.mint(liquidator, 1000e18);
    }

    function testConstructorValidations() public {
        vm.expectRevert(StableCoinEngine.ZeroAddress.selector);
        new StableCoinEngine(address(0), address(collateral), owner);

        vm.expectRevert(StableCoinEngine.ZeroAddress.selector);
        new StableCoinEngine(address(stableCoin), address(0), owner);

        vm.expectRevert(StableCoinEngine.SameTokens.selector);
        new StableCoinEngine(address(stableCoin), address(stableCoin), owner);

        vm.expectRevert(StableCoinEngine.InvalidERC20.selector);
        new StableCoinEngine(address(stableCoin), address(this), owner);
    }

    function testInitialState() public {
        assertEq(engine.stableCoin(), address(stableCoin));
        assertEq(engine.collateralToken(), address(collateral));
        assertEq(engine.owner(), owner);
    }

    function testUpdate() public {
        vm.warp(block.timestamp + 1 hours);
        engine.update(5100000000); // $51
    }

    function testValidPriceModifier() public {
        vm.expectRevert(StableCoinEngine.ZeroPrice.selector);
        engine.update(0);
    }

    function testNotTooFrequentModifier() public {
        // First update should work
        engine.update(5000000000);

        // Second update too soon should fail
        vm.expectRevert(abi.encodeWithSelector(StableCoinEngine.UpdateTooFrequent.selector, 0, engine.MIN_UPDATE_DELAY()));
        engine.update(5100000000);

        // After MIN_UPDATE_DELAY, update should work
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5100000000);
    }

    function testPriceChangeInRangeModifier() public {
        // First update should work
        engine.update(5000000000);

        // Wait required time
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());

        // Price change too big should fail (more than 10%)
        vm.expectRevert(abi.encodeWithSelector(StableCoinEngine.PriceChangeTooBig.selector, 5000000000, 5600000000));
        engine.update(5600000000); // $56, more than 10% increase

        // Price change within range should work
        engine.update(5100000000); // $51, less than 10% increase
    }

    function testDataValidationModifiers() public {
        // Test NoData modifier
        vm.expectRevert(StableCoinEngine.NoData.selector);
        engine.getLatestPrice();

        // Add one observation
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000);

        // Test sufficientData modifier
        vm.expectRevert(StableCoinEngine.InsufficientData.selector);
        engine.getTWAP();

        // Add second observation
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5100000000);

        // Now TWAP should work
        assertGt(engine.getTWAP(), 0);
    }

    function testGetObservationsCount() public {
        assertEq(engine.getObservationsCount(), 0);
    }

    function testGetCollateralPrice() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000); // $50 with 8 decimals

        uint256 collateralPrice = engine.getCollateralPrice();
        assertEq(collateralPrice, 50e18);
    }

    function testTWAPCalculation() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000); // $50 with 8 decimals

        uint256 twap = engine.getTWAP();
        assertEq(twap, 5000000000);
    }

    function testCalculateRequiredCollateral() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000); // $50 with 8 decimals

        uint256 mintAmount = 100e18;
        uint256 requiredCollateral = engine.calculateRequiredCollateral(mintAmount);
        assertEq(requiredCollateral, 3e18);
    }

    function testDepositAndMint() public {
        uint256 collateralAmount = 3e18;
        uint256 mintAmount = 100e18;

        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + 1 hours);
        engine.update(5000000000); // $50 with 8 decimals

        // Approve collateral transfer
        vm.startPrank(user);
        collateral.approve(address(engine), collateralAmount);

        // Deposit and mint
        engine.depositAndMint(collateralAmount, mintAmount);
        vm.stopPrank();

        // Verify position
        (uint256 posCollateral, uint256 posDebt, uint256 posLiqPrice,) = engine.positions(user);
        assertEq(posCollateral, collateralAmount, "Wrong collateral amount");
        assertEq(posDebt, mintAmount, "Wrong debt amount");

        // Verify liquidation price
        // debtValue = 100e18 * 1e8 = 100e26
        // liquidationThreshold = 120e16 (120%)
        // liquidationPrice = (100e26 * 120e16) / (3e18 * 1e18) = 40e8 ($40)
        uint256 expectedLiquidationPrice = 4000000000;
        assertEq(posLiqPrice, expectedLiquidationPrice, "Wrong liquidation price");

        emit log_named_uint("Actual liquidation price", posLiqPrice);
        emit log_named_uint("Expected liquidation price", expectedLiquidationPrice);
        emit log_named_uint("Debt amount", mintAmount);
        emit log_named_uint("Collateral amount", collateralAmount);
        emit log_named_uint("Liquidation threshold", engine.liquidationThreshold());
    }

    function testNotStaleDataModifier() public {
        // First update
        engine.update(5000000000);

        // Second update after MIN_UPDATE_DELAY
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000);

        // Wait for the data to become stale
        vm.warp(block.timestamp + engine.MAX_PRICE_AGE() + 1);

        // Try to get TWAP, should revert with StaleData
        vm.expectRevert(abi.encodeWithSelector(StableCoinEngine.StaleData.selector, block.timestamp - engine.MAX_PRICE_AGE() - 1));
        engine.getTWAP();
    }

    function testIsLiquidatable() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000); // $50 with 8 decimals

        // Set up initial position
        uint256 collateralAmount = 3e18;
        uint256 mintAmount = 100e18;

        vm.startPrank(user);
        collateral.approve(address(engine), collateralAmount);
        engine.depositAndMint(collateralAmount, mintAmount);
        vm.stopPrank();

        // Initially not liquidatable
        assertFalse(engine.isLiquidatable(user));

        // Drop price gradually to make position liquidatable
        uint256 startPrice = 4500000000;
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
            engine.update(startPrice - i * 100000000);
        }

        // Wait for TWAP to catch up
        vm.warp(block.timestamp + 12 hours);

        // Position should now be liquidatable
        assertTrue(engine.isLiquidatable(user));
    }

    function testLiquidateFullPosition() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + 1 hours);
        engine.update(5000000000); // $50 with 8 decimals

        // Set up initial position
        uint256 collateralAmount = 3e18;
        uint256 mintAmount = 100e18;

        vm.startPrank(user);
        collateral.approve(address(engine), collateralAmount);
        engine.depositAndMint(collateralAmount, mintAmount);
        vm.stopPrank();

        // Drop price gradually to make position liquidatable
        uint256 startPrice = 4500000000;
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
            engine.update(startPrice - i * 100000000); // Drop more aggressively
        }

        // Wait for TWAP to catch up
        vm.warp(block.timestamp + 12 hours);

        // Record initial balances
        uint256 initialLiquidatorCollateral = collateral.balanceOf(liquidator);
        uint256 initialUserCollateral = collateral.balanceOf(user);
        uint256 initialLiquidatorStable = stableCoin.balanceOf(liquidator);
        uint256 initialUserStable = stableCoin.balanceOf(user);

        // Mint stablecoins to liquidator
        vm.prank(address(engine));
        stableCoin.mint(liquidator, mintAmount);

        // Prepare liquidator
        vm.startPrank(liquidator);
        stableCoin.approve(address(engine), mintAmount);

        // Calculate expected values
        uint256 twap = engine.getTWAP();
        uint256 collateralToLiquidate = (mintAmount * engine.PRICE_PRECISION()) / twap;
        uint256 bonus = (collateralToLiquidate * engine.liquidationBonus()) / 1e18;
        uint256 totalCollateralToTransfer = collateralToLiquidate + bonus;

        // Expect events
        vm.expectEmit(true, true, false, true);
        emit PositionLiquidated(
            user,
            address(liquidator),
            mintAmount,
            collateralToLiquidate,
            bonus
        );

        // Liquidate position
        engine.liquidate(user, mintAmount);
        vm.stopPrank();

        // Verify position is cleared
        (uint256 posCollateral, uint256 posDebt, uint256 posLiqPrice,) = engine.positions(user);
        assertEq(posCollateral, 0, "Collateral not fully liquidated");
        assertEq(posDebt, 0, "Debt not fully repaid");
        assertEq(posLiqPrice, 0, "Liquidation price not reset");

        // Verify collateral transfer
        assertEq(collateral.balanceOf(liquidator), initialLiquidatorCollateral + totalCollateralToTransfer, "Wrong collateral transfer");
        assertEq(collateral.balanceOf(user), initialUserCollateral, "User collateral should not change");
        assertEq(stableCoin.balanceOf(liquidator), initialLiquidatorStable + mintAmount - mintAmount, "Wrong stable transfer");
        assertEq(stableCoin.balanceOf(user), initialUserStable, "User stable should not change");
    }

    function testPartialLiquidation() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + 1 hours);
        engine.update(5000000000); // $50 with 8 decimals

        // Set up initial position
        uint256 collateralAmount = 3e18;
        uint256 mintAmount = 100e18;

        vm.startPrank(user);
        collateral.approve(address(engine), collateralAmount);
        engine.depositAndMint(collateralAmount, mintAmount);
        vm.stopPrank();

        // Drop price gradually to make position liquidatable
        uint256 startPrice = 4500000000;
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
            engine.update(startPrice - i * 100000000); // Drop more aggressively
        }

        // Wait for TWAP to catch up
        vm.warp(block.timestamp + 12 hours);

        // Record initial balances
        uint256 initialLiquidatorCollateral = collateral.balanceOf(liquidator);
        uint256 initialUserCollateral = collateral.balanceOf(user);
        uint256 initialLiquidatorStable = stableCoin.balanceOf(liquidator);
        uint256 initialUserStable = stableCoin.balanceOf(user);

        // Prepare liquidator
        uint256 partialRepayment = mintAmount / 2; // Repay half the debt

        // Mint stablecoins to liquidator
        vm.prank(address(engine));
        stableCoin.mint(liquidator, partialRepayment);

        vm.startPrank(liquidator);
        stableCoin.approve(address(engine), partialRepayment);

        // Calculate expected values
        uint256 twap = engine.getTWAP();
        uint256 collateralToLiquidate = (partialRepayment * engine.PRICE_PRECISION()) / twap;
        uint256 bonus = (collateralToLiquidate * engine.liquidationBonus()) / 1e18;
        uint256 totalCollateralToTransfer = collateralToLiquidate + bonus;

        // Expect events
        vm.expectEmit(true, true, false, true);
        emit PositionLiquidated(
            user,
            address(liquidator),
            partialRepayment,
            collateralToLiquidate,
            bonus
        );

        // Liquidate half the position
        engine.liquidate(user, partialRepayment);
        vm.stopPrank();

        // Verify position is partially liquidated
        (uint256 posCollateral, uint256 posDebt, uint256 posLiqPrice,) = engine.positions(user);
        assertGt(posCollateral, 0, "Collateral fully liquidated");
        assertEq(posDebt, mintAmount - partialRepayment, "Wrong remaining debt");
        assertGt(posLiqPrice, 0, "Liquidation price not updated");

        // Verify collateral transfer
        assertEq(collateral.balanceOf(liquidator), initialLiquidatorCollateral + totalCollateralToTransfer, "Wrong collateral transfer");
        assertEq(collateral.balanceOf(user), initialUserCollateral, "User collateral should not change");
        assertEq(stableCoin.balanceOf(liquidator), initialLiquidatorStable + partialRepayment - partialRepayment, "Wrong stable transfer");
        assertEq(stableCoin.balanceOf(user), initialUserStable, "User stable should not change");
    }

    function testLiquidateWithInsufficientRepayment() public {
        // Initialize price feed
        engine.update(5000000000); // $50 with 8 decimals
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        engine.update(5000000000); // $50 with 8 decimals

        // Set up initial position
        uint256 collateralAmount = 3e18;
        uint256 mintAmount = 100e18;

        vm.startPrank(user);
        collateral.approve(address(engine), collateralAmount);
        engine.depositAndMint(collateralAmount, mintAmount);
        vm.stopPrank();

        // Drop price gradually to make position liquidatable
        uint256 startPrice = 4500000000;
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
            engine.update(startPrice - i * 100000000);
        }

        // Wait for TWAP to catch up
        vm.warp(block.timestamp + 12 hours);

        // Try to liquidate with insufficient repayment
        vm.startPrank(liquidator);
        vm.expectRevert(StableCoinEngine.InsufficientRepayment.selector);
        engine.liquidate(user, mintAmount + 1);
        vm.stopPrank();
    }
}
