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
        
        // TWAP calculation:
        // Time period 1: 1000 * 5 minutes = 5000 * minutes
        // Time period 2: 1100 * 5 minutes = 5500 * minutes
        // Total time = 10 minutes
        // TWAP = (5000 + 5500) / 10 = 1050
        uint256 expectedTWAP = 1050;
        
        vm.expectEmit(address(engine));
        emit TWAP(expectedTWAP);
        uint256 twap = engine.getTWAP();
        assertEq(twap, expectedTWAP);
    }

    function testGetObservationsCount() public {
        assertEq(engine.getObservationsCount(), 0);
        
        engine.update(1000);
        assertEq(engine.getObservationsCount(), 1);
        
        vm.warp(block.timestamp + 5 minutes);
        engine.update(1100);
        assertEq(engine.getObservationsCount(), 2);
    }
}
