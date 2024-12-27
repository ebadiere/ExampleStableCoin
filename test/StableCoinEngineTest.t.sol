// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoinEngine.sol";
import "../src/StableCoin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

error OwnableUnauthorizedAccount(address account);

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract InvalidToken {
    // This contract doesn't implement ERC20
}

contract StableCoinEngineTest is Test {
    StableCoinEngine public engine;
    StableCoin public stableCoin;
    MockERC20 public collateral;
    address public owner;
    address public user;

    event Update(uint256 currentPrice);
    event TWAP(uint256 twap);

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        collateral = new MockERC20();
        stableCoin = new StableCoin(owner);
        engine = new StableCoinEngine(
            address(stableCoin),
            address(collateral),
            owner
        );
    }

    function testInitialState() public {
        assertEq(engine.stableCoin(), address(stableCoin));
        assertEq(engine.collateralToken(), address(collateral));
        assertEq(engine.PERIOD(), 1 hours);
        assertEq(engine.MAX_PRICE_CHANGE_PERCENTAGE(), 10);
        assertEq(engine.MAX_PRICE_AGE(), 1 days);
        assertEq(engine.MIN_UPDATE_DELAY(), 5 minutes);
        assertEq(engine.PRICE_PRECISION(), 1e18);
        assertEq(engine.baseCollateralRatio(), 150e16); // 150%
        assertEq(engine.liquidationThreshold(), 120e16); // 120%
        assertEq(engine.mintFee(), 1e16); // 1%
        assertEq(engine.burnFee(), 5e15); // 0.5%
    }

    // Constructor Validation Tests
    function testConstructorValidations() public {
        // Test zero address validation
        vm.expectRevert(StableCoinEngine.ZeroAddress.selector);
        new StableCoinEngine(
            address(0),
            address(collateral),
            owner
        );

        vm.expectRevert(StableCoinEngine.ZeroAddress.selector);
        new StableCoinEngine(
            address(stableCoin),
            address(0),
            owner
        );

        // Test same tokens validation
        vm.expectRevert(StableCoinEngine.SameTokens.selector);
        new StableCoinEngine(
            address(collateral),
            address(collateral),
            owner
        );

        // Test invalid ERC20 validation
        InvalidToken invalidToken = new InvalidToken();
        vm.expectRevert(StableCoinEngine.InvalidERC20.selector);
        new StableCoinEngine(
            address(invalidToken),
            address(collateral),
            owner
        );
    }

    // Modifier: validPrice
    function testValidPriceModifier() public {
        vm.expectRevert(StableCoinEngine.ZeroPrice.selector);
        engine.update(0);

        // Valid price should work
        engine.update(1000);
    }

    // Modifier: notTooFrequent
    function testNotTooFrequentModifier() public {
        // First update should work
        engine.update(1000);

        // Immediate second update should fail
        vm.expectRevert(abi.encodeWithSelector(
            StableCoinEngine.UpdateTooFrequent.selector,
            0,
            5 minutes
        ));
        engine.update(1100);

        // Update after delay should work
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);
    }

    // Modifier: priceChangeInRange
    function testPriceChangeInRangeModifier() public {
        // First update should work
        engine.update(1000);

        // Wait required time
        vm.warp(block.timestamp + 5 minutes);

        // 11% increase should fail (>10% max change)
        vm.expectRevert(abi.encodeWithSelector(
            StableCoinEngine.PriceChangeTooBig.selector,
            1000,
            1110
        ));
        engine.update(1110);

        // 11% decrease should fail
        vm.expectRevert(abi.encodeWithSelector(
            StableCoinEngine.PriceChangeTooBig.selector,
            1000,
            890
        ));
        engine.update(890);

        // 10% increase should work
        engine.update(1100);

        // Wait and 10% decrease should work
        vm.warp(block.timestamp + 5 minutes);
        engine.update(990);
    }

    // Modifier: sufficientData and hasData
    function testDataValidationModifiers() public {
        // getTWAP should fail with no data
        vm.expectRevert(StableCoinEngine.InsufficientData.selector);
        engine.getTWAP();

        // getLatestPrice should fail with no data
        vm.expectRevert(StableCoinEngine.NoData.selector);
        engine.getLatestPrice();

        // Add one observation
        engine.update(1000);

        // getTWAP should still fail with only one observation
        vm.expectRevert(StableCoinEngine.InsufficientData.selector);
        engine.getTWAP();

        // getLatestPrice should work with one observation
        assertEq(engine.getLatestPrice(), 1000);

        // Add second observation
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);

        // Both should work with two observations
        engine.getTWAP();
        assertEq(engine.getLatestPrice(), 1100);
    }

    // Modifier: notStaleData
    function testNotStaleDataModifier() public {
        // Add two observations
        engine.update(1000);
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);

        // Should work before MAX_PRICE_AGE
        engine.getTWAP();

        // Should fail after MAX_PRICE_AGE
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(
            StableCoinEngine.StaleData.selector,
            block.timestamp - 1 days - 1 - 5 minutes
        ));
        engine.getTWAP();
    }

    // Ownable Tests
    function testOnlyOwnerModifier() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            OwnableUnauthorizedAccount.selector,
            user
        ));
        engine.update(1000);

        // Should work with owner
        engine.update(1000);
    }

    // Main Functionality Tests
    function testUpdate() public {
        uint256 price = 1000;
        
        vm.expectEmit(address(engine));
        emit Update(price);
        engine.update(price);
        
        (uint256 timestamp, uint256 storedPrice) = engine.observations(0);
        assertEq(storedPrice, price);
        assertEq(timestamp, block.timestamp);
    }

    function testTWAPCalculation() public {
        // First observation at t=0
        engine.update(1000);
        
        // Second observation at t=5min: price=1100
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);
        
        // Third observation at t=10min: price=1200
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1200);

        // Wait 5 minutes to test current time impact
        vm.warp(block.timestamp + 5 minutes);
        
        // TWAP calculation:
        // Time period 1: 1000 * 5 minutes = 5000 * minutes
        // Time period 2: 1100 * 5 minutes = 5500 * minutes
        // Time period 3: 1200 * 5 minutes = 6000 * minutes
        // Total time = 15 minutes
        // TWAP = (5000 + 5500 + 6000) / 15 = 1100
        uint256 expectedTWAP = 1100;
        
        uint256 twap = engine.getTWAP();
        assertEq(twap, expectedTWAP);
    }

    function testGetCollateralPrice() public {
        // First observation at t=0 (price in 1e8 precision)
        engine.update(50_00000000); // $50.00
        
        // Second observation at t=5min: price=$55.00
        vm.warp(block.timestamp + 5 minutes);
        engine.update(55_00000000);

        // Wait 5 minutes to test current time impact
        vm.warp(block.timestamp + 5 minutes);
        
        // TWAP calculation:
        // Period 1: 50_00000000 * 5 minutes = 250_00000000 * minutes (first price * time to second observation)
        // Period 2: 55_00000000 * 5 minutes = 275_00000000 * minutes (last price * time to current)
        // Total time = 10 minutes
        // TWAP = (250_00000000 + 275_00000000) / 10 = 52.50_00000000 (in 1e8 precision)
        // Expected collateral price = 52.50_00000000 * 1e18 / 1e8 = 52.50e18
        uint256 expectedPrice = 52500000000000000000;
        
        uint256 collateralPrice = engine.getCollateralPrice();
        assertEq(collateralPrice, expectedPrice);
    }

    function testCalculateRequiredCollateral() public {
        // Setup: Set collateral price to $50.00
        engine.update(50_00000000); // Initial price in 1e8 precision
        vm.warp(block.timestamp + 5 minutes);
        engine.update(52_50000000); // $52.50 (5% increase)

        // Wait 5 minutes to test current time impact
        vm.warp(block.timestamp + 5 minutes);
        
        // Test Case 1: Mint 100 stablecoins
        // TWAP calculation:
        // Period 1: 50_00000000 * 5 minutes = 250_00000000 * minutes (first price * time to second observation)
        // Period 2: 52_50000000 * 5 minutes = 262_50000000 * minutes (last price * time to current)
        // Total time = 10 minutes
        // TWAP = (250_00000000 + 262_50000000) / 10 = 51.25_00000000 (in 1e8 precision)
        // Collateral price = 51.25_00000000 * 1e18 / 1e8 = 51.25e18
        // Required collateral = (100e18 * 150e16 * 1e18) / (51.25e18 * 1e18)
        // ≈ 2.926829268292682926e18 collateral tokens
        uint256 mintAmount = 100e18;
        uint256 expectedCollateral = 2926829268292682926;
        uint256 requiredCollateral = engine.calculateRequiredCollateral(mintAmount);
        assertEq(requiredCollateral, expectedCollateral, "Case 1: Basic calculation failed");

        // Test Case 2: Mint 1 stablecoin (test small amounts)
        mintAmount = 1e18;
        expectedCollateral = 29268292682926829; // ≈ 0.02926829268292682926 collateral tokens
        requiredCollateral = engine.calculateRequiredCollateral(mintAmount);
        assertEq(requiredCollateral, expectedCollateral, "Case 2: Small amount calculation failed");

        // Test Case 3: Mint 0 stablecoins (should return 0)
        mintAmount = 0;
        expectedCollateral = 0;
        requiredCollateral = engine.calculateRequiredCollateral(mintAmount);
        assertEq(requiredCollateral, expectedCollateral, "Case 3: Zero amount calculation failed");

        // Test Case 4: Test with different collateral price
        // Update price to $53.00 (within 5% increase)
        vm.warp(block.timestamp + 5 minutes);
        engine.update(53_00000000);

        // Wait 5 minutes to test current time impact
        vm.warp(block.timestamp + 5 minutes);
        
        // TWAP calculation for Case 4:
        // Period 1: 52_50000000 * 5 minutes = 262_50000000 * minutes (first price * time to second observation)
        // Period 2: 53_00000000 * 5 minutes = 265_00000000 * minutes (last price * time to current)
        // Total time = 10 minutes
        // TWAP = (262_50000000 + 265_00000000) / 10 = 52.75_00000000 (in 1e8 precision)
        // Collateral price = 52.75_00000000 * 1e18 / 1e8 = 52.75e18
        // Required collateral = (100e18 * 150e16 * 1e18) / (52.75e18 * 1e18)
        // ≈ 2.884615384615384615e18 collateral tokens
        mintAmount = 100e18;
        expectedCollateral = 2884615384615384615;
        requiredCollateral = engine.calculateRequiredCollateral(mintAmount);
        assertEq(requiredCollateral, expectedCollateral, "Case 4: Different price calculation failed");
    }

    function testGetObservationsCount() public {
        assertEq(engine.getObservationsCount(), 0);
        
        engine.update(1000);
        assertEq(engine.getObservationsCount(), 1);
        
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);
        assertEq(engine.getObservationsCount(), 2);
    }

    function testIsLiquidatable() public {
        // Setup initial price at $50.00
        engine.update(50_00000000);
        vm.warp(block.timestamp + 5 minutes);
        engine.update(50_00000000);
        
        emit log_named_uint("Initial TWAP", engine.getTWAP());

        // Create a test position
        StableCoinEngine.Position memory position = StableCoinEngine.Position({
            collateralAmount: 1e18,
            debtAmount: 100e18,
            liquidationPrice: 47_00000000, // $47.00
            lastInterestUpdate: block.timestamp
        });

        // Store the position using storage slot manipulation
        bytes32 positionSlot = keccak256(abi.encode(user, uint256(6))); // slot 6 is positions mapping
        vm.store(address(engine), positionSlot, bytes32(position.collateralAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(user, uint256(6)))) + 1), bytes32(position.debtAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(user, uint256(6)))) + 2), bytes32(position.liquidationPrice));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(user, uint256(6)))) + 3), bytes32(position.lastInterestUpdate));

        // Test 1: Position should not be liquidatable when price is above liquidation price
        emit log_named_uint("TWAP before price drops", engine.getTWAP());
        assertFalse(engine.isLiquidatable(user), "Position should not be liquidatable at $50.00");

        // Test 2: Position should be liquidatable when price drops below liquidation price
        // First drop to $48.00 (4% drop)
        vm.warp(block.timestamp + 30 minutes);
        engine.update(48_00000000);
        emit log_named_uint("TWAP after first drop", engine.getTWAP());
        
        // Then drop to $46.00 (4.17% drop, within 10% limit)
        vm.warp(block.timestamp + 30 minutes);
        engine.update(46_00000000);
        emit log_named_uint("TWAP after second drop", engine.getTWAP());
        
        // Wait longer for TWAP to update (4 hours)
        vm.warp(block.timestamp + 4 hours);
        engine.update(46_00000000);
        
        // Wait another 4 hours to let TWAP fully reflect the lower price
        vm.warp(block.timestamp + 4 hours);
        engine.update(46_00000000);
        
        emit log_named_uint("TWAP after waiting", engine.getTWAP());
        emit log_named_uint("Liquidation price", position.liquidationPrice);
        
        assertTrue(engine.isLiquidatable(user), "Position should be liquidatable at $46.00");

        // Test 3: Empty position should not be liquidatable
        address emptyUser = address(0x2);
        StableCoinEngine.Position memory emptyPosition = StableCoinEngine.Position({
            collateralAmount: 0,
            debtAmount: 0,
            liquidationPrice: 0,
            lastInterestUpdate: 0
        });

        positionSlot = keccak256(abi.encode(emptyUser, uint256(6)));
        vm.store(address(engine), positionSlot, bytes32(emptyPosition.collateralAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(emptyUser, uint256(6)))) + 1), bytes32(emptyPosition.debtAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(emptyUser, uint256(6)))) + 2), bytes32(emptyPosition.liquidationPrice));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(emptyUser, uint256(6)))) + 3), bytes32(emptyPosition.lastInterestUpdate));

        assertFalse(engine.isLiquidatable(emptyUser), "Empty position should not be liquidatable");

        // Test 4: Position with debt but no liquidation price should not be liquidatable
        address invalidUser = address(0x3);
        StableCoinEngine.Position memory invalidPosition = StableCoinEngine.Position({
            collateralAmount: 1e18,
            debtAmount: 100e18,
            liquidationPrice: 0,
            lastInterestUpdate: block.timestamp
        });

        positionSlot = keccak256(abi.encode(invalidUser, uint256(6)));
        vm.store(address(engine), positionSlot, bytes32(invalidPosition.collateralAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(invalidUser, uint256(6)))) + 1), bytes32(invalidPosition.debtAmount));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(invalidUser, uint256(6)))) + 2), bytes32(invalidPosition.liquidationPrice));
        vm.store(address(engine), bytes32(uint256(keccak256(abi.encode(invalidUser, uint256(6)))) + 3), bytes32(invalidPosition.lastInterestUpdate));

        assertFalse(engine.isLiquidatable(invalidUser), "Position without liquidation price should not be liquidatable");
    }
}
